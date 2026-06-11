#!/usr/bin/env bash
# session-janitor setup — discovers gateways, generates config, installs cron
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$SKILL_DIR/config.json"
OS="$(uname -s)"

echo "=== Session Janitor Setup ==="
echo ""

# --- Discover gateways ---
echo "Scanning for OpenClaw gateway installations..."
gateways=()
gateway_dirs=()

# Check standard locations
for candidate in "$HOME/.openclaw" "$HOME/.openclaw-"*; do
    [[ -d "$candidate" ]] || continue
    [[ -f "$candidate/openclaw.json" ]] || continue

    config_json="$candidate/openclaw.json"
    sessions_dir="$candidate/agents/main/sessions"

    if [[ ! -d "$sessions_dir" ]]; then
        echo "  ⚠ Found $candidate but no sessions dir — skipping"
        continue
    fi

    # Extract name from dir
    dirname=$(basename "$candidate")
    if [[ "$dirname" == ".openclaw" ]]; then
        name="default"
    else
        name="${dirname#.openclaw-}"
    fi

    # Extract port from config
    port=$(python3 -c "
import json
c = json.load(open('$config_json'))
print(c.get('gateway',{}).get('port', c.get('port', 18789)))
" 2>/dev/null || echo "18789")

    # Extract auth token
    token=$(python3 -c "
import json
c = json.load(open('$config_json'))
print(c.get('gateway',{}).get('auth',{}).get('token',''))
" 2>/dev/null || echo "")

    echo "  ✓ Found gateway: $name (${candidate}, port $port)"
    gateways+=("$name")
    gateway_dirs+=("$candidate")
done

if [[ ${#gateways[@]} -eq 0 ]]; then
    echo ""
    echo "❌ No OpenClaw gateway installations found."
    echo "   Expected: ~/.openclaw/openclaw.json or ~/.openclaw-*/openclaw.json"
    exit 1
fi

echo ""
echo "Found ${#gateways[@]} gateway(s): ${gateways[*]}"
echo ""

# --- Check for mem CLI ---
mem_available=false
mem_path=""
if command -v mem &>/dev/null; then
    mem_available=true
    mem_path=$(command -v mem)
    echo "✓ mem CLI found at $mem_path"
elif [[ -x "$HOME/bin/mem" ]]; then
    mem_available=true
    mem_path="$HOME/bin/mem"
    echo "✓ mem CLI found at $mem_path"
elif [[ -x "$HOME/.npm-global/bin/mem" ]]; then
    mem_available=true
    mem_path="$HOME/.npm-global/bin/mem"
    echo "✓ mem CLI found at $mem_path"
else
    echo "ℹ mem CLI not found — Archy backend not available"
fi

# --- Memory backend selection ---
echo ""
echo "Memory extraction after trim:"
echo "  1) Archy (mem CLI)$([ "$mem_available" == true ] && echo " [found: $mem_path]" || echo " [mem CLI not found]")"
echo "  2) Generic HTTP webhook (POST each memory as JSON to a URL)"
echo "  3) Scene files only (no external system — git-backed markdown files)"
echo "  4) Disabled (no extraction)"
echo ""

default_mem_choice=3
[[ "$mem_available" == true ]] && default_mem_choice=1

read -r -p "Choice [default: $default_mem_choice]: " mem_choice
mem_choice="${mem_choice:-$default_mem_choice}"

mem_backend_type="scene-only"
webhook_url=""
webhook_headers_json="{}"

case "$mem_choice" in
  1)
    if [[ "$mem_available" == true ]]; then
        mem_backend_type="archy"
        echo "  ✓ Archy backend selected ($mem_path)"
    else
        echo "  ⚠ mem CLI not found — falling back to scene-only"
        mem_backend_type="scene-only"
    fi
    ;;
  2)
    mem_backend_type="webhook"
    read -r -p "  Webhook URL: " webhook_url
    read -r -p "  Authorization header value (leave blank for none): " webhook_auth
    if [[ -n "$webhook_auth" ]]; then
        webhook_headers_json="{\"Authorization\": \"$webhook_auth\"}"
    fi
    echo "  ✓ Webhook backend selected ($webhook_url)"
    ;;
  3)
    mem_backend_type="scene-only"
    echo "  ✓ Scene files only"
    ;;
  4)
    mem_backend_type="none"
    echo "  ✓ Memory extraction disabled"
    ;;
  *)
    echo "  ⚠ Invalid choice — defaulting to scene-only"
    mem_backend_type="scene-only"
    ;;
esac

# --- Check for Python 3 ---
if ! command -v python3 &>/dev/null; then
    echo "❌ python3 is required but not found"
    exit 1
fi
echo "✓ python3 found"

# --- Check OS-specific watcher dependency ---
if [[ "$OS" == "Darwin" ]]; then
    if command -v fswatch &>/dev/null; then
        echo "✓ fswatch found (per-turn watcher)"
    else
        echo "⚠ fswatch not found — per-turn watcher will not work"
        echo "  Install with: brew install fswatch"
        echo "  (cron-based trimming every 15 min will still work without it)"
    fi
else
    if command -v inotifywait &>/dev/null; then
        echo "✓ inotifywait found (per-turn watcher)"
    else
        echo "⚠ inotifywait not found — per-turn watcher will not work"
        echo "  Install with: sudo apt install inotify-tools (or equivalent)"
        echo "  (cron-based trimming every 15 min will still work without it)"
    fi
fi

# --- Generate config ---
echo ""
echo "Generating config.json..."

python3 - "$CONFIG_FILE" "$mem_backend_type" "$mem_path" "$webhook_url" "$webhook_headers_json" "${gateways[@]}" <<'PYEOF'
import json, sys, os, subprocess

config_file = sys.argv[1]
mem_backend_type = sys.argv[2]
mem_cli_path = sys.argv[3]
webhook_url = sys.argv[4]
webhook_headers_json = sys.argv[5]
gateway_names = sys.argv[6:]
try:
    webhook_headers = json.loads(webhook_headers_json)
except Exception:
    webhook_headers = {}

gateways = []
for name in gateway_names:
    if name == "default":
        config_dir = os.path.expanduser("~/.openclaw")
    else:
        config_dir = os.path.expanduser(f"~/.openclaw-{name}")

    config_json = os.path.join(config_dir, "openclaw.json")
    sessions_dir = os.path.join(config_dir, "agents/main/sessions")

    port = 18789
    token = ""
    try:
        c = json.load(open(config_json))
        port = c.get("gateway", {}).get("port", c.get("port", 18789))
        token = c.get("gateway", {}).get("auth", {}).get("token", "")
    except:
        pass

    gateways.append({
        "name": name,
        "configDir": config_dir,
        "sessionsDir": sessions_dir,
        "port": port,
        "token": token,
    })

config = {
    "gateways": gateways,
    "trimMaxKB": 250,
    "keepPairs": 10,
    "keepFullPairs": 2,
    "minArchivePairs": 5,
    "trimFullThresholdPct": 50,
    "archiveRetentionDays": 7,
    "orphanGraceMinutes": 30,
    "staleSubagentHours": 24,
    "staleCronSessionHours": 24,
    "llmExtraction": {
        "enabled": mem_backend_type != "none",
        "maxPerRun": 1,
        "model": "openclaw",
        "maxInputChars": 20000,
        "timeoutSecs": 60,
        "maxMemories": 15,
        "minArchived": 3,
    },
    "memBackend": {
        "type": mem_backend_type,
        **({"webhookUrl": webhook_url, "webhookHeaders": webhook_headers}
           if mem_backend_type == "webhook" else {}),
    },
    "memCli": {
        "enabled": mem_backend_type == "archy" and bool(mem_cli_path),
        "path": mem_cli_path or "mem",
    },
    "stateFile": os.path.expanduser("~/.openclaw/session-janitor-state.json"),
    "watcherDebounceSecs": 3,
    "cronSchedule": "*/15 * * * *",
    "logFile": "/tmp/session-janitor.log",
}

json.dump(config, open(config_file, "w"), indent=2)
print(f"  Written to {config_file}")
PYEOF

echo ""

# --- Install cron ---
JANITOR_SCRIPT="$SKILL_DIR/scripts/janitor.sh"
CRON_SCHEDULE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('cronSchedule','*/15 * * * *'))")
LOG_FILE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('logFile','/tmp/session-janitor.log'))")

CRON_LINE="$CRON_SCHEDULE $JANITOR_SCRIPT >> $LOG_FILE 2>&1"

# Check if already installed
if crontab -l 2>/dev/null | grep -qF "session-janitor"; then
    echo "Updating existing cron entry..."
    crontab -l 2>/dev/null | grep -v "session-janitor" | { cat; echo "$CRON_LINE  # session-janitor"; } | crontab -
else
    echo "Installing cron entry..."
    (crontab -l 2>/dev/null; echo "$CRON_LINE  # session-janitor") | crontab -
fi

echo "  ✓ Cron installed: $CRON_SCHEDULE"
echo ""

# --- Install watcher service (systemd on Linux, launchd on macOS) ---
if [[ "$OS" == "Darwin" ]]; then
    PLIST_TEMPLATE="$SKILL_DIR/session-janitor-watcher.plist"
    LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
    PLIST_LABEL="ai.openclaw.session-janitor-watcher"
    PLIST_DEST="$LAUNCH_AGENTS_DIR/${PLIST_LABEL}.plist"

    if [[ -f "$PLIST_TEMPLATE" ]]; then
        mkdir -p "$LAUNCH_AGENTS_DIR"
        sed "s|SKILL_DIR_PLACEHOLDER|$SKILL_DIR|g" "$PLIST_TEMPLATE" > "$PLIST_DEST"
        launchctl unload "$PLIST_DEST" 2>/dev/null || true
        launchctl load "$PLIST_DEST" 2>/dev/null && \
            echo "  ✓ Watcher LaunchAgent installed and started" || \
            echo "  ⚠ LaunchAgent load failed — check: launchctl list | grep session-janitor"
        echo "  Location: $PLIST_DEST"
        echo "  Stop:     launchctl unload \"$PLIST_DEST\""
        echo "  Start:    launchctl load \"$PLIST_DEST\""
    else
        echo "  ⚠ Plist template not found at $PLIST_TEMPLATE — skipping watcher service"
    fi
else
    # Linux — systemd user service
    SERVICE_TEMPLATE="$SKILL_DIR/session-janitor-watcher.service"
    SERVICE_DIR="$HOME/.config/systemd/user"
    SERVICE_DEST="$SERVICE_DIR/session-janitor-watcher.service"

    if [[ -f "$SERVICE_TEMPLATE" ]]; then
        mkdir -p "$SERVICE_DIR"
        sed "s|SKILL_DIR_PLACEHOLDER|$SKILL_DIR|g" "$SERVICE_TEMPLATE" > "$SERVICE_DEST"
        systemctl --user daemon-reload
        systemctl --user enable --now session-janitor-watcher.service 2>/dev/null && \
            echo "  ✓ Watcher service enabled and started" || \
            echo "  ⚠ Watcher service install failed — check: systemctl --user status session-janitor-watcher"
    else
        echo "  ⚠ Service template not found at $SERVICE_TEMPLATE — skipping watcher service"
    fi
fi

echo ""

# --- Verify ---
echo "=== Setup Complete ==="
echo ""
echo "Config:    $CONFIG_FILE"
echo "Script:    $JANITOR_SCRIPT"
echo "Log:       $LOG_FILE"
echo "Schedule:  $CRON_SCHEDULE"
echo ""
echo "Test with: bash $JANITOR_SCRIPT"
echo "Logs:      tail -f $LOG_FILE"
if [[ "$OS" == "Darwin" ]]; then
    echo "Watcher:   tail -f /tmp/session-janitor-watcher.log"
    echo "           launchctl list | grep session-janitor"
else
    echo "Watcher:   tail -f /tmp/session-janitor-watcher.log"
    echo "           systemctl --user status session-janitor-watcher"
fi
