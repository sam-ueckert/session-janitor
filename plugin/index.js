/**
 * OpenClaw Session Janitor Plugin
 *
 * Hooks:
 *   session_start / session_end  — track sessionKey → {sessionId, transcriptPath}
 *   before_agent_finalize        — record transcript path only (NO file writes)
 *   agent_end                    — spawn detached sidecar+trim subprocess
 *   gateway_start                — startup probe
 *
 * WHY agent_end instead of before_agent_finalize for trim:
 *   before_agent_finalize runs while OC still holds the session integrity check.
 *   Calling trim.py there (which atomically renames the JSONL) causes OC to
 *   detect "session file changed while embedded prompt lock was released" and
 *   throw EmbeddedAttemptSessionTakeoverError.
 *
 *   agent_end fires AFTER OC has fully committed the turn and released the
 *   session. We spawn trim-with-sidecar.sh as a detached process so it returns
 *   immediately and the file write happens after OC is done.
 */

import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN_ID = "session-janitor";

const sessionState = new Map(); // sessionKey → { sessionId, transcriptPath, gateway, pendingPreTrimFile? }

export default {
  register(api) {
    const raw = api.logger ?? console;
    const info = (msg) => (raw.info ?? raw.log ?? console.log)(`[${PLUGIN_ID}] ${msg}`);
    const warn = (msg) => (raw.warn ?? console.warn)(`[${PLUGIN_ID}] ${msg}`);

    // ── Config ────────────────────────────────────────────────────────────────
    const pluginRoot = api.rootDir ?? __dirname;
    const configPath = path.resolve(pluginRoot, "..", "config.json");
    let cfg = {};
    try {
      cfg = JSON.parse(fs.readFileSync(configPath, "utf8"));
      info(`config loaded from ${configPath}`);
    } catch {
      warn(`no config.json at ${configPath}, using defaults`);
    }

    const scriptsDir = path.resolve(pluginRoot, "..", "scripts");
    const trimMaxKb = cfg.trimMaxKB ?? 250;
    const keepPairs = cfg.keepPairs ?? 10;
    const keepFullPairs = cfg.keepFullPairs ?? 2;
    const minArchivePairs = cfg.minArchivePairs ?? 5;
    const trimFullPct = cfg.trimFullThresholdPct ?? 50;
    const stateFile = (cfg.stateFile ?? "~/.openclaw/session-janitor-state.json")
      .replace(/^~/, process.env.HOME ?? "~");
    const sidecarEnabled = cfg.sidecar?.enabled !== false;
    const sidecarMinBytes = cfg.sidecar?.minEntryBytes ?? 5120;
    const llmEnabled = Boolean(cfg.llmExtraction?.enabled);
    const llmGatewayName = cfg.llmExtraction?.gateway ?? "";
    const gateways = cfg.gateways ?? [];

    function fileSizeKb(p) {
      try { return Math.floor(fs.statSync(p).size / 1024); } catch { return 0; }
    }

    function sk(event, ctx) { return event?.sessionKey ?? ctx?.sessionKey ?? null; }
    function sid(event, ctx) { return event?.sessionId ?? ctx?.sessionId ?? null; }

    function latestPreTrimFile(transcriptPath) {
      const dir = path.dirname(transcriptPath);
      const base = path.basename(transcriptPath);
      try {
        return fs.readdirSync(dir)
          .filter((f) => f.startsWith(base + ".pre-trim."))
          .map((f) => path.join(dir, f))
          .sort().reverse()[0] ?? null;
      } catch { return null; }
    }

    // ── Hook: session_start ───────────────────────────────────────────────────
    api.on("session_start", (event, ctx) => {
      const key = sk(event, ctx);
      const id = sid(event, ctx);
      if (key && id) sessionState.set(key, { sessionId: id });
    });

    // ── Hook: session_end ─────────────────────────────────────────────────────
    api.on("session_end", (event, ctx) => {
      const key = sk(event, ctx);
      if (key) sessionState.delete(key);
    });

    // ── Hook: before_agent_finalize ───────────────────────────────────────────
    // IMPORTANT: Do NOT call trim.py or sidecar.py here. Modifying the JSONL
    // inside this hook causes EmbeddedAttemptSessionTakeoverError because OC
    // checks file integrity after the hook returns.
    // This hook only caches the transcript path for agent_end to use.
    api.on("before_agent_finalize", (event, ctx) => {
      const { transcriptPath, sessionId: id, sessionKey: key } = event;
      if (!transcriptPath || !key || key.includes(":subagent:")) return;
      const state = sessionState.get(key) ?? { sessionId: id };
      state.transcriptPath = transcriptPath;
      state.gateway = path.basename(
        path.dirname(path.dirname(path.dirname(transcriptPath)))
      );
      sessionState.set(key, state);
    });

    // ── Hook: agent_end ───────────────────────────────────────────────────────
    // OC has fully released the session after this fires. Spawn trim as a
    // detached process so the file write happens after OC is clear.
    api.on("agent_end", async (event, ctx) => {
      if (!event.success) return;

      const key = sk(event, ctx);
      if (!key || key.includes(":subagent:")) return;

      const state = sessionState.get(key);
      const transcriptPath = state?.transcriptPath;

      if (transcriptPath && fs.existsSync(transcriptPath)) {
        const sizeBefore = fileSizeKb(transcriptPath);
        if (sizeBefore > trimMaxKb) {
          const id = state?.sessionId ?? path.basename(transcriptPath, ".jsonl");
          const gateway = state?.gateway ?? "unknown";
          info(`${id.slice(0, 8)}: ${sizeBefore}KB — spawning detached sidecar+trim`);

          // Detached: returns immediately; process runs after OC releases session
          spawn(
            "bash",
            [
              path.join(scriptsDir, "trim-with-sidecar.sh"),
              transcriptPath,
              id,
              gateway,
              stateFile,
              String(keepPairs),
              String(keepFullPairs),
              String(minArchivePairs),
              String(trimFullPct),
              String(trimMaxKb),
              String(sidecarEnabled ? sidecarMinBytes : 0),
            ],
            { detached: true, stdio: "ignore" }
          ).unref();
        }
      }

      // LLM extraction from previous trim's pre-trim archive
      if (llmEnabled && state?.pendingPreTrimFile) {
        const { pendingPreTrimFile, pendingTranscriptPath, pendingGateway, sessionId: id } = state;
        delete state.pendingPreTrimFile;
        delete state.pendingTranscriptPath;
        delete state.pendingGateway;

        const gwCfg = gateways.find((g) => g.name === llmGatewayName) ?? gateways[0];
        if (gwCfg) {
          const llmApiUrl = `http://127.0.0.1:${gwCfg.port}`;
          info(`${(id ?? "?").slice(0, 8)}: spawning async LLM extraction`);
          spawn(
            "python3",
            [
              path.join(scriptsDir, "extract-llm.py"),
              pendingPreTrimFile,
              pendingTranscriptPath ?? "",
              id ?? "",
              pendingGateway ?? gwCfg.name,
              stateFile,
              `${llmApiUrl}/v1/chat/completions`,
              gwCfg.token ?? "",
              "true",
              cfg.llmExtraction?.memPath ?? "mem",
              cfg.llmExtraction?.scene ?? "",
              cfg.llmExtraction?.model ?? "openclaw",
              String(cfg.llmExtraction?.maxInputChars ?? 20_000),
              String(cfg.llmExtraction?.timeoutSecs ?? 60),
              String(cfg.llmExtraction?.maxMemories ?? 15),
              String(cfg.llmExtraction?.minArchived ?? 3),
            ],
            { detached: true, stdio: "ignore" }
          ).unref();
        }
      }
    });

    // ── Hook: gateway_start ───────────────────────────────────────────────────
    api.on("gateway_start", (event) => {
      info(`active on port ${event?.port ?? "?"} — hooks: session_start, session_end, before_agent_finalize, agent_end, gateway_start`);
      console.log(`[session-janitor] GATEWAY_START fired on port ${event?.port}`);
    });

    info(`registered: session_start, session_end, before_agent_finalize, agent_end, gateway_start`);
  },
};
