#!/usr/bin/env bash
# session-janitor watcher — per-turn trim trigger (Linux: inotifywait, macOS: fswatch)
# Watches all gateway session dirs. On JSONL write, debounces 3s then fires trim.
set -euo pipefail

OS="$(uname -s)"

export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if [[ "$OS" == "Linux" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
fi

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"
CONFIG_FILE="$SKILL_DIR/config.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: $CONFIG_FILE not found" >&2
    exit 1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [watcher] $*"; }

# Load config values
read_config_val() {
    python3 -c "
import json, os
c = json.load(open('$CONFIG_FILE'))
print(c.get('$1', '$2'))
"
}

TRIM_MAX_KB=$(read_config_val trimMaxKB 250)
KEEP_PAIRS=$(read_config_val keepPairs 10)
KEEP_FULL_PAIRS=$(read_config_val keepFullPairs 2)
MIN_ARCHIVE_PAIRS=$(read_config_val minArchivePairs 5)
TRIM_FULL_THRESHOLD_PCT=$(read_config_val trimFullThresholdPct 50)
DEBOUNCE_SECS=$(read_config_val watcherDebounceSecs 3)
STATE_FILE=$(python3 -c "import json,os; c=json.load(open('$CONFIG_FILE')); print(os.path.expanduser(c.get('stateFile','~/.openclaw/session-janitor-state.json')))")
SIDECAR_ENABLED=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(str(c.get('sidecar',{}).get('enabled',True)).lower())")
SIDECAR_MIN_BYTES=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('sidecar',{}).get('minEntryBytes',5120))")

# Build list of watch dirs + gateway metadata
get_gateways() {
    python3 -c "
import json, os
c = json.load(open('$CONFIG_FILE'))
for gw in c.get('gateways', []):
    sd = os.path.expanduser(gw.get('sessionsDir', ''))
    name = gw.get('name', '')
    port = gw.get('port', '')
    token = gw.get('token', '')
    cfgdir = os.path.expanduser(gw.get('configDir', ''))
    if sd and os.path.isdir(sd):
        print(f'{name}|{sd}|{port}|{token}|{cfgdir}')
"
}

# Associative maps: dir -> gateway info
declare -A DIR_NAME DIR_PORT DIR_TOKEN DIR_CFG

while IFS='|' read -r name sd port token cfgdir; do
    DIR_NAME["$sd"]="$name"
    DIR_PORT["$sd"]="$port"
    DIR_TOKEN["$sd"]="$token"
    DIR_CFG["$sd"]="$cfgdir"
done < <(get_gateways)

WATCH_DIRS=("${!DIR_NAME[@]}")

if [[ ${#WATCH_DIRS[@]} -eq 0 ]]; then
    log "No valid session dirs found — exiting"
    exit 1
fi

log "Watching ${#WATCH_DIRS[@]} session dir(s): ${WATCH_DIRS[*]}"
log "Threshold: ${TRIM_MAX_KB}KB | Debounce: ${DEBOUNCE_SECS}s | Keep pairs: ${KEEP_PAIRS} | Keep full pairs: ${KEEP_FULL_PAIRS}"

# Pending file => timestamp of last event
declare -A PENDING

# Portable file size in KB (GNU stat -c vs BSD stat -f)
get_file_size_kb() {
    local f="$1"
    if [[ "$OS" == "Darwin" ]]; then
        echo $(( $(stat -f%z "$f" 2>/dev/null || echo 0) / 1024 ))
    else
        echo $(( $(stat -c%s "$f" 2>/dev/null || echo 0) / 1024 ))
    fi
}

fire_trim() {
    local jsonl="$1"
    local sessions_dir
    sessions_dir="$(dirname "$jsonl")"
    local name="${DIR_NAME[$sessions_dir]:-unknown}"
    local port="${DIR_PORT[$sessions_dir]:-}"
    local token="${DIR_TOKEN[$sessions_dir]:-}"
    local cfgdir="${DIR_CFG[$sessions_dir]:-}"

    # Skip non-active files
    [[ "$jsonl" == *".reset."* ]] && return
    [[ "$jsonl" == *".deleted."* ]] && return
    [[ "$jsonl" == *".pre-trim."* ]] && return
    [[ ! -f "$jsonl" ]] && return

    local size_kb
    size_kb=$(get_file_size_kb "$jsonl")

    if (( size_kb <= TRIM_MAX_KB )); then
        return  # Under threshold — skip
    fi

    local sid
    sid=$(basename "$jsonl" .jsonl)

    # Verify it's an active session
    local sessions_json="$sessions_dir/sessions.json"
    if [[ -f "$sessions_json" ]]; then
        if ! python3 -c "
import json, sys
d = json.load(open('$sessions_json'))
active = [v.get('sessionId','') for v in d.get('sessions',d).values()]
sys.exit(0 if '$sid' in active else 1)
" 2>/dev/null; then
            return  # Not an active session
        fi
    fi

    log "$name: $sid is ${size_kb}KB — trimming"

    # Run sidecar offloader first (before trim so trim sees smaller file)
    if [[ "$SIDECAR_ENABLED" == "true" ]]; then
        if python3 "$SCRIPTS_DIR/sidecar.py" "$jsonl" "$sid" "$SIDECAR_MIN_BYTES" 2>&1 | while IFS= read -r line; do log "$name: [sidecar] $line"; done; then
            : # sidecar ran (even if nothing was offloaded, exit 0)
        else
            log "$name: sidecar failed for $sid (exit $?) — continuing to trim"
        fi
        # Recheck size after sidecar (it may have shrunk the file below threshold)
        size_kb=$(get_file_size_kb "$jsonl")
        if (( size_kb <= TRIM_MAX_KB )); then
            log "$name: $sid shrank to ${size_kb}KB after sidecar — skipping trim"
            # Still ping gateway so it reloads the updated transcript
            if [[ -n "$token" && -n "$port" && -n "$sessions_json" ]]; then
                local session_key
                session_key=$(python3 -c "
import json
d = json.load(open('$sessions_json'))
for k, v in d.get('sessions', d).items():
    if v.get('sessionId','') == '$sid':
        print(k)
        break
" 2>/dev/null)
                if [[ -n "$session_key" ]]; then
                    curl -sS --max-time 10 "http://127.0.0.1:${port}/v1/chat/completions" \
                        -H "Authorization: Bearer $token" \
                        -H "Content-Type: application/json" \
                        -H "x-openclaw-session-key: $session_key" \
                        -d '{"model":"openclaw","messages":[{"role":"user","content":"[tool outputs sidecared — acknowledge with NO_REPLY]"}]}' \
                        >/dev/null 2>&1 && log "$name: gateway reload pinged after sidecar for $session_key" || true
                fi
            fi
            return
        fi
    fi

    if python3 "$SCRIPTS_DIR/trim.py" "$jsonl" "$sid" "$name" "$STATE_FILE" "$KEEP_PAIRS" "$KEEP_FULL_PAIRS" "$MIN_ARCHIVE_PAIRS" "$TRIM_FULL_THRESHOLD_PCT" "$TRIM_MAX_KB" 2>&1; then
        log "$name: trim complete for $sid"

        # Ping gateway to reload
        if [[ -n "$token" && -n "$port" ]]; then
            local session_key
            session_key=$(python3 -c "
import json
d = json.load(open('$sessions_json'))
for k, v in d.get('sessions', d).items():
    if v.get('sessionId','') == '$sid':
        print(k)
        break
" 2>/dev/null)
            if [[ -n "$session_key" ]]; then
                # Skip sub-agent sessions — the reload ping re-triggers full runs on them
                if [[ "$session_key" == *":subagent:"* ]]; then
                    log "$name: skipping reload ping for sub-agent session $session_key"
                else
                    curl -sS --max-time 10 "http://127.0.0.1:${port}/v1/chat/completions" \
                        -H "Authorization: Bearer $token" \
                        -H "Content-Type: application/json" \
                        -H "x-openclaw-session-key: $session_key" \
                        -d '{"model":"openclaw","messages":[{"role":"user","content":"[session trimmed by maintenance — acknowledge with NO_REPLY]"}]}' \
                        >/dev/null 2>&1 && log "$name: gateway reload pinged for $session_key" || true
                fi
            fi
        fi
    else
        log "$name: trim failed for $sid (exit $?)"
    fi
}

# Main loop: inotifywait feeds events, we debounce and fire
process_pending() {
    local now
    now=$(date +%s)
    for jsonl in "${!PENDING[@]}"; do
        local ts="${PENDING[$jsonl]}"
        if (( now - ts >= DEBOUNCE_SECS )); then
            unset "PENDING[$jsonl]"
            fire_trim "$jsonl" &
        fi
    done
}

# OS-specific file watcher — outputs one absolute path per line
start_watcher() {
    if [[ "$OS" == "Darwin" ]]; then
        if ! command -v fswatch &>/dev/null; then
            log "ERROR: fswatch not found — install with: brew install fswatch"
            exit 1
        fi
        # FSEvents backend: Updated covers writes, MovedTo covers atomic renames
        fswatch --event Updated --event MovedTo --latency 1 "${WATCH_DIRS[@]}"
    else
        inotifywait -m -e close_write,moved_to --format '%w%f' "${WATCH_DIRS[@]}" 2>/dev/null
    fi
}

start_watcher | while IFS= read -r filepath; do
    # Only care about .jsonl files (not .pre-trim., .reset., etc.)
    [[ "$filepath" == *.jsonl ]] || continue
    [[ "$filepath" == *".pre-trim."* ]] && continue
    [[ "$filepath" == *".reset."* ]] && continue
    [[ "$filepath" == *".deleted."* ]] && continue

    PENDING["$filepath"]=$(date +%s)

    # Check if any pending items are ready to fire
    process_pending
done
