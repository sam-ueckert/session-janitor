/**
 * OpenClaw Session Janitor Plugin
 *
 * Hooks:
 *   session_start / session_end  — track sessionKey → sessionId mapping
 *   before_agent_finalize        — sidecar + trim while OC holds the turn lock
 *   agent_end                    — async LLM extraction from archived content
 *
 * Eliminates the external watcher/cron-sweep sentinel approach. The
 * before_agent_finalize hook fires after the assistant response is written but
 * before cache-ttl, so there is no race window and no need to inspect file
 * content to determine turn state.
 */

import fs from "node:fs";
import path from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN_ID = "session-janitor";

// Per-session state tracked across hooks
const sessionState = new Map(); // sessionKey → { sessionId, pendingPreTrimFile? }

export default {
  register(api) {
    const raw = api.logger ?? console;
    const info = (msg) => (raw.info ?? raw.log ?? console.log)(`[${PLUGIN_ID}] ${msg}`);
    const warn = (msg) => (raw.warn ?? console.warn)(`[${PLUGIN_ID}] ${msg}`);
    const logErr = (msg) => (raw.error ?? console.error)(`[${PLUGIN_ID}] ${msg}`);

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
    const stateFile = cfg.stateFile
      ? cfg.stateFile.replace(/^~/, process.env.HOME ?? "~")
      : path.join(process.env.HOME ?? "~", ".openclaw", "session-janitor-state.json");
    const sidecarEnabled = cfg.sidecar?.enabled !== false;
    const sidecarMinBytes = cfg.sidecar?.minEntryBytes ?? 5120;
    const llmEnabled = Boolean(cfg.llmExtraction?.enabled);
    const llmGatewayName = cfg.llmExtraction?.gateway ?? "";
    const gateways = cfg.gateways ?? [];

    // ── Helpers ───────────────────────────────────────────────────────────────
    function latestPreTrimFile(transcriptPath) {
      const dir = path.dirname(transcriptPath);
      const base = path.basename(transcriptPath);
      try {
        return (
          fs
            .readdirSync(dir)
            .filter((f) => f.startsWith(base + ".pre-trim."))
            .map((f) => path.join(dir, f))
            .sort()
            .reverse()[0] ?? null
        );
      } catch {
        return null;
      }
    }

    function fileSizeKb(p) {
      try {
        return Math.floor(fs.statSync(p).size / 1024);
      } catch {
        return 0;
      }
    }

    function sessionKey(event, ctx) {
      return event?.sessionKey ?? ctx?.sessionKey ?? null;
    }

    function sessionId(event, ctx) {
      return event?.sessionId ?? ctx?.sessionId ?? null;
    }

    // ── Hook: session_start ───────────────────────────────────────────────────
    api.on("session_start", (event, ctx) => {
      const sk = sessionKey(event, ctx);
      const sid = sessionId(event, ctx);
      if (sk && sid) {
        sessionState.set(sk, { sessionId: sid });
      }
    });

    // ── Hook: session_end ─────────────────────────────────────────────────────
    api.on("session_end", (event, ctx) => {
      const sk = sessionKey(event, ctx);
      if (sk) sessionState.delete(sk);
    });

    // ── Hook: before_agent_finalize ───────────────────────────────────────────
    // Fires after the assistant response is committed, before cache-ttl write.
    // OC holds the session lock throughout, so there is no external race.
    api.on(
      "before_agent_finalize",
      async (event, ctx) => {
        const { transcriptPath, sessionId: sid, sessionKey: sk } = event;

        if (!transcriptPath || !fs.existsSync(transcriptPath)) return;

        // Skip subagent transcripts — they're short-lived and managed by OC
        if (sk?.includes(":subagent:")) return;

        const sizeBefore = fileSizeKb(transcriptPath);
        if (sizeBefore <= trimMaxKb) return;

        const shortId = (sid ?? path.basename(transcriptPath, ".jsonl")).slice(0, 8);
        const gateway = path.basename(
          path.dirname(path.dirname(path.dirname(transcriptPath))) // …/<name>/agents/main/sessions/<file>
        );

        info(`${shortId}: ${sizeBefore}KB > ${trimMaxKb}KB — sidecar + trim`);

        // ── Step 1: sidecar ───────────────────────────────────────────────────
        if (sidecarEnabled) {
          try {
            const out = execFileSync(
              "python3",
              [
                path.join(scriptsDir, "sidecar.py"),
                transcriptPath,
                sid ?? path.basename(transcriptPath, ".jsonl"),
                String(sidecarMinBytes),
              ],
              { encoding: "utf8", timeout: 30_000 }
            );
            if (out.trim()) info(`${shortId}: sidecar: ${out.trim().split("\n").pop()}`);
          } catch (e) {
            warn(`${shortId}: sidecar error: ${e.message?.split("\n")[0]}`);
          }
        }

        const sizeAfterSidecar = fileSizeKb(transcriptPath);
        if (sizeAfterSidecar <= trimMaxKb) {
          info(`${shortId}: ${sizeAfterSidecar}KB after sidecar — under threshold, done`);
          return;
        }

        // ── Step 2: trim ──────────────────────────────────────────────────────
        try {
          const out = execFileSync(
            "python3",
            [
              path.join(scriptsDir, "trim.py"),
              transcriptPath,
              sid ?? path.basename(transcriptPath, ".jsonl"),
              gateway,
              stateFile,
              String(keepPairs),
              String(keepFullPairs),
              String(minArchivePairs),
              String(trimFullPct),
              String(trimMaxKb),
            ],
            { encoding: "utf8", timeout: 30_000 }
          );
          if (out.trim()) info(`${shortId}: trim: ${out.trim().split("\n").pop()}`);

          const sizeAfterTrim = fileSizeKb(transcriptPath);
          info(`${shortId}: done — ${sizeBefore}KB → ${sizeAfterTrim}KB`);

          // Record pre-trim file for LLM extraction in agent_end
          if (llmEnabled && sk) {
            const preTrim = latestPreTrimFile(transcriptPath);
            if (preTrim) {
              const state = sessionState.get(sk) ?? { sessionId: sid };
              state.pendingPreTrimFile = preTrim;
              state.pendingTranscriptPath = transcriptPath;
              state.pendingGateway = gateway;
              sessionState.set(sk, state);
            }
          }
        } catch (e) {
          warn(`${shortId}: trim error: ${e.message?.split("\n")[0]}`);
        }
      },
      { timeoutMs: 60_000 }
    );

    // ── Hook: agent_end ───────────────────────────────────────────────────────
    // Fires after the turn is fully complete. Safe to fire async work here.
    if (llmEnabled) {
      api.on("agent_end", async (event, ctx) => {
        if (!event.success) return;

        const sk = sessionKey(event, ctx);
        if (!sk) return;

        const state = sessionState.get(sk);
        if (!state?.pendingPreTrimFile) return;

        const { pendingPreTrimFile, pendingTranscriptPath, pendingGateway, sessionId: sid } = state;
        delete state.pendingPreTrimFile;
        delete state.pendingTranscriptPath;
        delete state.pendingGateway;

        const gwCfg =
          gateways.find((g) => g.name === llmGatewayName) ?? gateways[0];
        if (!gwCfg) return;

        const llmApiUrl = `http://127.0.0.1:${gwCfg.port}`;
        const shortId = (sid ?? "unknown").slice(0, 8);
        info(`${shortId}: launching async LLM extraction`);

        spawn(
          "python3",
          [
            path.join(scriptsDir, "extract-llm.py"),
            pendingPreTrimFile,
            pendingTranscriptPath ?? "",
            sid ?? "",
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
      });
    }

    // gateway_start fires once at gateway startup — confirms plugin is active at runtime
    api.on("gateway_start", (event, ctx) => {
      info(`active on port ${event?.port ?? "?"} — hooks: ${hooks.join(", ")}`);
      console.log(`[session-janitor] GATEWAY_START fired on port ${event?.port}`);
    });

    const hooks = ["session_start", "session_end", "before_agent_finalize", "gateway_start"];
    if (llmEnabled) hooks.push("agent_end");
    info(`registered: ${hooks.join(", ")}`);
  },
};
