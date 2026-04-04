#!/usr/bin/env bash
# session-janitor setup — discovers gateways, generates config, installs cron
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$SKILL_DIR/config.json"

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
    echo "ℹ mem CLI not found — LLM extraction will skip structured memory storage"
    echo "  (Memories will still be extracted, just not stored in a searchable DB)"
fi

# --- Check for Python 3 ---
if ! command -v python3 &>/dev/null; then
    echo "❌ python3 is required but not found"
    exit 1
fi
echo "✓ python3 found"

# --- Generate config ---
echo ""
echo "Generating config.json..."

python3 - "$CONFIG_FILE" "${gateways[@]}" <<'PYEOF'
import json, sys, os, subprocess

config_file = sys.argv[1]
gateway_names = sys.argv[2:]

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

# Check for mem
mem_path = ""
for candidate in [
    subprocess.run(["which", "mem"], capture_output=True, text=True).stdout.strip(),
    os.path.expanduser("~/bin/mem"),
    os.path.expanduser("~/.npm-global/bin/mem"),
]:
    if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
        mem_path = candidate
        break

config = {
    "gateways": gateways,
    "trimMaxKB": 250,
    "keepPairs": 10,
    "archiveRetentionDays": 7,
    "orphanGraceMinutes": 30,
    "staleSubagentHours": 24,
    "staleCronSessionHours": 24,
    "llmExtraction": {
        "enabled": True,
        "maxPerRun": 1,
        "maxInputChars": 20000,
        "timeoutSecs": 60,
    },
    "memCli": {
        "enabled": bool(mem_path),
        "path": mem_path,
    },
    "stateFile": os.path.expanduser("~/.openclaw/session-janitor-state.json"),
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
