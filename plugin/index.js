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
    const memCliPath = (cfg.memCli?.path ?? cfg.llmExtraction?.memPath ?? "mem")
      .replace(/^~/, process.env.HOME ?? "~");
    const memBackendType = cfg.memBackend?.type ?? (cfg.memCli?.enabled ? "archy" : "scene-only");
    const memBackendWebhookUrl = cfg.memBackend?.webhookUrl ?? "";
    const memBackendWebhookHeaders = JSON.stringify(cfg.memBackend?.webhookHeaders ?? {});

    function fileSizeKb(p) {
      try { return Math.floor(fs.statSync(p).size / 1024); } catch { return 0; }
    }

    function sk(event, ctx) { return event?.sessionKey ?? ctx?.sessionKey ?? null; }
    function sid(event, ctx) { return event?.sessionId ?? ctx?.sessionId ?? null; }

    // Resolve transcript path from sessions.json when the hook event omits it.
    // OC does NOT reliably populate event.transcriptPath, but sessions.json
    // stores `sessionFile` (full path) per session key. We resolve from there,
    // searching across gateway store dirs so this works for both gateways.
    const STORE_DIRS = (cfg.gateways ?? [])
      .map((g) => g.sessionsDir)
      .filter(Boolean);
    // Fallback: derive from this gateway's own location if not configured.
    function candidateSessionsJsonPaths() {
      const paths = [];
      for (const d of STORE_DIRS) paths.push(path.join(d, "sessions.json"));
      // Common layouts relative to HOME
      const home = process.env.HOME ?? "";
      for (const gw of [".openclaw-slack", ".openclaw-discord", ".openclaw"]) {
        paths.push(path.join(home, gw, "agents", "main", "sessions", "sessions.json"));
      }
      return [...new Set(paths)];
    }
    function resolveTranscriptFromStore(key, id) {
      for (const sjPath of candidateSessionsJsonPaths()) {
        try {
          if (!fs.existsSync(sjPath)) continue;
          const data = JSON.parse(fs.readFileSync(sjPath, "utf8"));
          const sessions = data.sessions ?? data;
          const entry = (key && sessions[key]) || null;
          let file = entry?.sessionFile ?? entry?.transcriptPath ?? null;
          // If keyed lookup failed, try matching by sessionId across entries.
          if (!file && id) {
            for (const v of Object.values(sessions)) {
              if (v && typeof v === "object" && v.sessionId === id) {
                file = v.sessionFile ?? v.transcriptPath ?? null;
                if (file) break;
              }
            }
          }
          if (file && fs.existsSync(file)) return file;
        } catch { /* try next */ }
      }
      return null;
    }

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
      const key = event?.sessionKey ?? ctx?.sessionKey ?? null;
      const id = event?.sessionId ?? ctx?.sessionId ?? null;
      let { transcriptPath } = event;
      if (!key || key.includes(":subagent:")) return;
      const state = sessionState.get(key) ?? { sessionId: id };
      if (transcriptPath) {
        state.transcriptPath = transcriptPath;
        const sessDir = path.dirname(transcriptPath);
        const matchedGw = gateways.find(
          (g) => g.sessionsDir && path.resolve(sessDir) === path.resolve(g.sessionsDir)
        );
        state.gateway = matchedGw?.name
          ?? path.basename(path.dirname(path.dirname(path.dirname(transcriptPath))));
      }
      if (id) state.sessionId = id;
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
      const id = state?.sessionId ?? sid(event, ctx);
      // Prefer cached path from before_agent_finalize; fall back to sessions.json.
      let transcriptPath = state?.transcriptPath;
      if (!transcriptPath || !fs.existsSync(transcriptPath)) {
        const resolved = resolveTranscriptFromStore(key, id);
        if (resolved) {
          transcriptPath = resolved;
          const st = sessionState.get(key) ?? { sessionId: id };
          st.transcriptPath = resolved;
          const resolvedSessDir = path.dirname(resolved);
          const resolvedGw = gateways.find(
            (g) => g.sessionsDir && path.resolve(resolvedSessDir) === path.resolve(g.sessionsDir)
          );
          st.gateway = resolvedGw?.name
            ?? path.basename(path.dirname(path.dirname(path.dirname(resolved))));
          if (id) st.sessionId = id;
          sessionState.set(key, st);
        }
      }

      const finalState = sessionState.get(key) ?? state;
      if (transcriptPath && fs.existsSync(transcriptPath)) {
        const sizeBefore = fileSizeKb(transcriptPath);
        if (sizeBefore > trimMaxKb) {
          const tid = finalState?.sessionId ?? id ?? path.basename(transcriptPath, ".jsonl");
          const gateway = finalState?.gateway
            ?? path.basename(path.dirname(path.dirname(path.dirname(transcriptPath))));
          info(`${tid.slice(0, 8)}: ${sizeBefore}KB — spawning detached sidecar+trim`);

          // Detached: returns immediately; process runs after OC releases session
          spawn(
            "bash",
            [
              path.join(scriptsDir, "trim-with-sidecar.sh"),
              transcriptPath,
              tid,
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
              String(cfg.memCli?.enabled !== false && memBackendType === "archy"),
              memCliPath,
              cfg.llmExtraction?.scene ?? "",
              cfg.llmExtraction?.model ?? "openclaw",
              String(cfg.llmExtraction?.maxInputChars ?? 20_000),
              String(cfg.llmExtraction?.timeoutSecs ?? 60),
              String(cfg.llmExtraction?.maxMemories ?? 15),
              String(cfg.llmExtraction?.minArchived ?? 3),
              memBackendType,
              memBackendWebhookUrl,
              memBackendWebhookHeaders,
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
