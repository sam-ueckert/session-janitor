#!/usr/bin/env bash
set -euo pipefail

PROFILE_DIR="$HOME/.openclaw-test"
OC_BIN="/usr/local/bin/openclaw"

# Write test credentials for Anthropic if a key is provided
if [[ -n "${OC_ANTHROPIC_KEY:-}" ]]; then
  mkdir -p "$PROFILE_DIR/credentials"
  cat > "$PROFILE_DIR/credentials/anthropic.json" <<JSON
{"apiKey": "${OC_ANTHROPIC_KEY}"}
JSON
fi

# Write plugin config that points at the test sessions dir
cat > /home/janitor/session-janitor/config.json <<JSON
{
  "gateways": [
    {
      "name": "test",
      "configDir": "${PROFILE_DIR}",
      "sessionsDir": "${PROFILE_DIR}/agents/main/sessions",
      "port": 18799,
      "token": "${OC_TEST_TOKEN:-janitor-test-token-abc123}"
    }
  ],
  "trimMaxKB": 5,
  "keepPairs": 3,
  "keepFullPairs": 1,
  "minArchivePairs": 1,
  "trimFullThresholdPct": 50,
  "archiveRetentionDays": 7,
  "orphanGraceMinutes": 5,
  "staleSubagentHours": 1,
  "staleCronSessionHours": 1,
  "stateFile": "/tmp/janitor-state.json",
  "sidecar": {
    "enabled": true,
    "minEntryBytes": 512
  },
  "llmExtraction": {
    "enabled": false
  }
}
JSON

PLUGIN_SRC="/home/janitor/session-janitor/plugin"

# Install plugin via openclaw plugins install (--link to avoid copy, --force to overwrite)
echo "[entrypoint] installing session-janitor plugin..."
env OPENCLAW_STATE_DIR="$PROFILE_DIR" "$OC_BIN" plugins install \
  --dangerously-force-unsafe-install \
  "$PLUGIN_SRC" 2>&1 || echo "[entrypoint] WARN: plugin install non-zero"

# Ensure the plugin entry is enabled in config
env OPENCLAW_STATE_DIR="$PROFILE_DIR" "$OC_BIN" plugins enable session-janitor 2>&1 || true

# Wire the installed plugin path into plugins.load.paths
PLUGIN_INSTALLED="$PROFILE_DIR/extensions/session-janitor"
env OPENCLAW_STATE_DIR="$PROFILE_DIR" "$OC_BIN" config set \
  plugins.load.paths "[\"$PLUGIN_INSTALLED\"]" 2>&1 || true

# Grant conversation access so before_agent_finalize fires
env OPENCLAW_STATE_DIR="$PROFILE_DIR" "$OC_BIN" config set \
  plugins.entries.session-janitor.hooks.allowConversationAccess true 2>&1 || true

echo "[entrypoint] starting OpenClaw gateway on port 18799 (OPENCLAW_STATE_DIR=$PROFILE_DIR)"

exec env OPENCLAW_STATE_DIR="$PROFILE_DIR" "$OC_BIN" gateway --port 18799
