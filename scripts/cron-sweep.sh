#!/bin/bash
# cron-sweep.sh — Periodic fallback sweep for oversized transcripts
#
# Backstop for inotify misses during rapid burst writes (compaction loops,
# heavy tool-call sequences). Runs every 2 min via cron.
#
# Cron entry (install via: crontab -e):
#   */2 * * * * /home/swabby/repos/swabby-brain/skills/session-janitor/scripts/cron-sweep.sh >> /tmp/session-janitor.log 2>&1

export PATH="/home/swabby/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$SKILL_DIR/config.json"
LOG_FILE="/tmp/session-janitor.log"
LOCK_FILE="/tmp/session-janitor-sweep.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [sweep] $*"; }

# Prevent overlapping runs
if [ -f "$LOCK_FILE" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
    if (( age < 110 )); then
        exit 0
    fi
    log "WARN: stale lock (${age}s) — removing"
fi
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Read config
TRIM_MAX_KB=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('trimMaxKB',300))" 2>/dev/null || echo 300)
KEEP_PAIRS=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('keepPairs',20))" 2>/dev/null || echo 20)
KEEP_FULL_PAIRS=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('keepFullPairs',4))" 2>/dev/null || echo 4)
MIN_ARCHIVE_PAIRS=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('minArchivePairs',5))" 2>/dev/null || echo 5)
TRIM_FULL_THRESHOLD_PCT=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('trimFullThresholdPct',50))" 2>/dev/null || echo 50)
STATE_FILE=$(python3 -c "import json,os; c=json.load(open('$CONFIG_FILE')); print(os.path.expanduser(c.get('stateFile','~/.openclaw/session-janitor-state.json')))" 2>/dev/null || echo "$HOME/.openclaw/session-janitor-state.json")

# Session dirs + gateway names from config
GATEWAYS=$(python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
for gw in c.get('gateways', []):
    print(gw['name'] + '|' + gw['sessionsDir'])
" 2>/dev/null)

swept=0
while IFS='|' read -r gw_name sessions_dir; do
    [ -d "$sessions_dir" ] || continue
    while IFS= read -r jsonl; do
        [ -f "$jsonl" ] || continue
        size_kb=$(( $(stat -c %s "$jsonl" 2>/dev/null || echo 0) / 1024 ))
        if (( size_kb > TRIM_MAX_KB )); then
            sid=$(basename "$jsonl" .jsonl)
            # Mid-turn guard: skip if agent is actively processing tool calls
            local_midturn=$(python3 - "$jsonl" <<'PYEOF'
import json, sys
# OC JSONL format: {type, id, parentId, timestamp, message: {role, content}}
# Top-level 'role' does NOT exist — must read entry['message']['role']
try:
    entries = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except Exception:
    print('ok'); sys.exit(0)
if not entries:
    print('ok'); sys.exit(0)
# Find last 'message' type entry
last_msg = None
for e in reversed(entries):
    if e.get('type') == 'message':
        last_msg = e.get('message', {})
        break
if last_msg is None:
    print('ok'); sys.exit(0)
role = last_msg.get('role', '')
if role == 'tool':
    print('midturn'); sys.exit(0)
content = last_msg.get('content', [])
if isinstance(content, list):
    for c in content:
        if isinstance(c, dict) and c.get('type') in ('tool_result', 'tool_use'):
            print('midturn'); sys.exit(0)
print('ok')
PYEOF
)
            if [[ "$local_midturn" == "midturn" ]]; then
                file_age_secs=$(( $(date +%s) - $(stat -c%Y "$jsonl" 2>/dev/null || echo 0) ))
                if (( file_age_secs < 90 )); then
                    log "$gw_name: $sid is mid-turn (${file_age_secs}s) — skipping sweep trim"
                    continue
                else
                    log "$gw_name: $sid mid-turn but stale (${file_age_secs}s) — treating as abandoned, trimming"
                fi
            fi
            log "$gw_name: sweep found $sid at ${size_kb}KB — trimming"
            if python3 "$SCRIPT_DIR/trim.py" \
                "$jsonl" "$sid" "$gw_name" "$STATE_FILE" \
                "$KEEP_PAIRS" "$KEEP_FULL_PAIRS" "$MIN_ARCHIVE_PAIRS" \
                "$TRIM_FULL_THRESHOLD_PCT" "$TRIM_MAX_KB" 2>&1; then
                log "$gw_name: sweep trim complete for $sid"
            else
                log "$gw_name: sweep trim FAILED for $sid (exit $?)"
            fi
            swept=$(( swept + 1 ))
        fi
    done < <(find "$sessions_dir" -maxdepth 1 -name "*.jsonl" \
        ! -name "*.pre-trim.*" ! -name "*.reset.*" \
        ! -name "*.deleted.*" ! -name "*.trajectory.*" \
        2>/dev/null)
done <<< "$GATEWAYS"

(( swept > 0 )) && log "sweep complete: $swept file(s) trimmed"
exit 0
