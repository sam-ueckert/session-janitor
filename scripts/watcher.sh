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

# Check if a session_key belongs to an active foreman worker (skip reload to avoid aborting in-flight requests)
ACTIVE_WORKERS_FILE="$HOME/repos/swabby-brain/memory/active-workers.json"
is_active_worker_session() {
    local sk="$1"
    [[ -f "$ACTIVE_WORKERS_FILE" ]] || return 1
    python3 -c "
import json, sys
sk = sys.argv[1]
try:
    d = json.load(open('$ACTIVE_WORKERS_FILE'))
    for w in d.get('workers', []):
        if w.get('session_key') == sk and w.get('status') in ('starting', 'running', 'blocked'):
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
" "$sk" 2>/dev/null
}

# Load config values
read_config_val() {
    python3 -c "
import json, os
c = json.load(open('$CONFIG_FILE'))
print(c.get('$1', '$2'))
"
}

# Load extractOnTrim config (re-read each time for live config updates)
read_extract_on_trim_val() {
    python3 -c "
import json, os
c = json.load(open('$CONFIG_FILE'))
print(c.get('extractOnTrim', {}).get('$1', '$2'))
"
}

TRIM_MAX_KB=$(read_config_val trimMaxKB 250)
TRIM_FORCE_KB=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('trimForceKB', int(c.get('trimMaxKB', 250) * 2)))" 2>/dev/null || echo $(( TRIM_MAX_KB * 2 )))
FORCE_TRIM_STALE_MINS=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('forceTrimStaleMins', 30))" 2>/dev/null || echo 30)
KEEP_PAIRS=$(read_config_val keepPairs 10)
KEEP_FULL_PAIRS=$(read_config_val keepFullPairs 2)
MIN_ARCHIVE_PAIRS=$(read_config_val minArchivePairs 5)
TRIM_FULL_THRESHOLD_PCT=$(read_config_val trimFullThresholdPct 50)
DEBOUNCE_SECS=$(read_config_val watcherDebounceSecs 3)
STATE_FILE=$(python3 -c "import json,os; c=json.load(open('$CONFIG_FILE')); print(os.path.expanduser(c.get('stateFile','~/.openclaw/session-janitor-state.json')))")
SIDECAR_ENABLED=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(str(c.get('sidecar',{}).get('enabled',True)).lower())")
SIDECAR_MIN_BYTES=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('sidecar',{}).get('minEntryBytes',5120))")
MEM_ENABLED=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(str(c.get('memCli',{}).get('enabled',False)).lower())")
MEM_PATH=$(python3 -c "import json,os; c=json.load(open('$CONFIG_FILE')); print(os.path.expanduser(c.get('memCli',{}).get('path','mem')))")
MEM_BACKEND_TYPE=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('memBackend',{}).get('type',''))")
MEM_BACKEND_WEBHOOK_URL=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('memBackend',{}).get('webhookUrl',''))")
MEM_BACKEND_WEBHOOK_HEADERS=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(json.dumps(c.get('memBackend',{}).get('webhookHeaders',{})))")

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
# declare -A PENDING  # removed — replaced by polling loop

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
    [[ "$jsonl" == *".trajectory."* ]] && return  # OpenClaw runtime telemetry, not a transcript
    [[ ! -f "$jsonl" ]] && return

    local size_kb
    size_kb=$(get_file_size_kb "$jsonl")

    if (( size_kb <= TRIM_MAX_KB )); then
        return  # Under threshold — skip
    fi

    local sid
    sid=$(basename "$jsonl" .jsonl)
    sid="${sid%.trajectory}"  # Strip .trajectory suffix so UUID matches sessions.json

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

    # Cache-ttl sentinel: only trim when OC has finished the current turn.
    # OC writes custom/openclaw.cache-ttl as the last JSONL entry after every complete turn.
    # If OC is still mid-turn or writing post-response cleanup, skip here — the next
    # inotify close_write (when OC writes cache-ttl) will re-trigger fire_trim naturally.
    local turn_state
    turn_state=$(python3 - <<'PYEOF'
import json, sys
try:
    entries = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except Exception:
    print('ok'); sys.exit(0)
if not entries:
    print('ok'); sys.exit(0)
last = entries[-1]
if last.get('type') == 'custom' and last.get('customType') == 'openclaw.cache-ttl':
    print('ok'); sys.exit(0)
last_msg = None
for e in reversed(entries):
    if e.get('type') == 'message':
        last_msg = e
        break
if last_msg is None:
    print('ok'); sys.exit(0)
role = last_msg.get('message', {}).get('role', '') or last_msg.get('role', '')
content = last_msg.get('message', {}).get('content', []) if 'message' in last_msg else last_msg.get('content', [])
if isinstance(content, list):
    for c in content:
        if isinstance(c, dict) and c.get('type') in ('tool_result', 'tool_use'):
            print('midturn'); sys.exit(0)
if role == 'assistant':
    print('pending'); sys.exit(0)
# Last message is user — OC received it and is waiting for model response
if role == 'user':
    print('midturn'); sys.exit(0)
print('ok')
PYEOF
        "$jsonl" 2>/dev/null)

    if [[ "$turn_state" != "ok" ]]; then
        # Force-trim override: if file is over hard ceiling AND stale (no writes in N min), trim anyway.
        # Prevents permanent skip when a session is stuck mid-turn (e.g. gateway timeouts).
        local force_trim=false
        if (( size_kb >= TRIM_FORCE_KB )); then
            local mtime_secs now_secs stale_secs
            mtime_secs=$(stat -c %Y "$jsonl" 2>/dev/null || echo 0)
            now_secs=$(date +%s)
            stale_secs=$(( (now_secs - mtime_secs) ))
            if (( stale_secs >= FORCE_TRIM_STALE_MINS * 60 )); then
                log "$name: $sid is ${size_kb}KB (>= force ${TRIM_FORCE_KB}KB) and stale ${stale_secs}s — force-trimming despite turn='$turn_state'"
                force_trim=true
            fi
        fi
        if [[ "$force_trim" != "true" ]]; then
            log "$name: $sid is ${size_kb}KB but turn is '$turn_state' — skipping (next write will re-check)"
            return
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
        # Recheck size after sidecar (sidecar offloads blobs but does NOT archive message pairs)
        # Always proceed to trim.py — sidecar is preprocessing, not a substitute for trim.
        size_kb=$(get_file_size_kb "$jsonl")
        log "$name: $sid is ${size_kb}KB after sidecar — proceeding to trim"
    fi

    if python3 "$SCRIPTS_DIR/trim.py" "$jsonl" "$sid" "$name" "$STATE_FILE" "$KEEP_PAIRS" "$KEEP_FULL_PAIRS" "$MIN_ARCHIVE_PAIRS" "$TRIM_FULL_THRESHOLD_PCT" "$TRIM_MAX_KB" 2>&1; then
        log "$name: trim complete for $sid"

        # Async memory extraction from archived content (if enabled)
        local extract_enabled
        extract_enabled=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(str(c.get('extractOnTrim',{}).get('enabled',False)).lower())" 2>/dev/null)
        if [[ "$extract_enabled" == "true" ]]; then
            # Find the .pre-trim.* archive written by trim.py
            local pre_trim_file
            pre_trim_file=$(ls -t "${jsonl}.pre-trim."* 2>/dev/null | head -1)
            if [[ -n "$pre_trim_file" ]]; then
                local extract_scene extract_salience extract_min
                extract_scene=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('extractOnTrim',{}).get('scene','auto'))" 2>/dev/null)
                extract_salience=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('extractOnTrim',{}).get('salience',0.5))" 2>/dev/null)
                extract_min=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('extractOnTrim',{}).get('minArchivedPairs',3))" 2>/dev/null)
                local gw_url="http://127.0.0.1:${port}"
                log "$name: firing async extract-llm for $sid (pre-trim: $pre_trim_file)"
                python3 "$SCRIPTS_DIR/extract-llm.py" \
                    "$pre_trim_file" "$jsonl" "$sid" "$gw_url" "$STATE_FILE" \
                    "${gw_url}/v1/chat/completions" "$token" \
                    "$MEM_ENABLED" "$MEM_PATH" "$extract_scene" "openclaw" "20000" "60" "15" "$extract_min" \
                    "$MEM_BACKEND_TYPE" "$MEM_BACKEND_WEBHOOK_URL" "$MEM_BACKEND_WEBHOOK_HEADERS" \
                    >> /tmp/janitor-extract.log 2>&1 &
                log "$name: extract-llm launched async (pid $!)"
            else
                log "$name: extractOnTrim enabled but no pre-trim file found for $sid"
            fi
        fi

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
                # Skip active foreman worker sessions — reload aborts in-flight API requests
                # Root-caused 2026-05-02: janitor reload POST killed workers mid-turn
                if is_active_worker_session "$session_key"; then
                    log "$name: skipping reload ping — active foreman worker session $session_key (trim still applied on disk)"
                elif [[ "$session_key" == *":direct:"* ]]; then
                    curl -sS --max-time 10 "http://127.0.0.1:${port}/v1/chat/completions" \
                        -H "Authorization: Bearer $token" \
                        -H "Content-Type: application/json" \
                        -H "x-openclaw-session-key: $session_key" \
                        -d '{"model":"openclaw","messages":[{"role":"user","content":"[session trimmed by maintenance — acknowledge with NO_REPLY]"}]}' \
                        >/dev/null 2>&1 && log "$name: gateway reload pinged for $session_key" || true
                else
                    log "$name: skipping reload ping for non-direct session $session_key (trim still applied on disk)"
                fi
            fi
        fi
    else
        log "$name: trim failed for $sid (exit $?)"
    fi
}

# Polling loop — runs entirely in the main process (no subshell/IPC issues).
# Scans all watch dirs every POLL_SECS and fires fire_trim for oversized files.
# Cooldown prevents re-firing the same file within COOLDOWN_SECS of last trim.
# The plugin (agent_end hook) is the primary trim trigger; this is belt-and-suspenders.
POLL_SECS=${DEBOUNCE_SECS:-5}
COOLDOWN_SECS=60

declare -A LAST_FIRED  # filepath -> epoch when fire_trim was last called

log "Starting poll loop (interval: ${POLL_SECS}s, cooldown: ${COOLDOWN_SECS}s)"

while true; do
    sleep "$POLL_SECS"
    now=$(date +%s)
    for sd in "${WATCH_DIRS[@]}"; do
        for jsonl in "$sd"/*.jsonl; do
            [[ -f "$jsonl" ]] || continue
            [[ "$jsonl" == *".pre-trim."* ]] && continue
            [[ "$jsonl" == *".reset."* ]] && continue
            [[ "$jsonl" == *".deleted."* ]] && continue
            [[ "$jsonl" == *".trajectory."* ]] && continue

            sz=$(get_file_size_kb "$jsonl")
            (( sz > TRIM_MAX_KB )) || continue

            # Cooldown: skip if we fired recently for this file
            last="${LAST_FIRED[$jsonl]:-0}"
            (( now - last < COOLDOWN_SECS )) && continue

            LAST_FIRED["$jsonl"]=$now
            fire_trim "$jsonl" &
        done
    done
done
