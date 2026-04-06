#!/usr/bin/env bash
# session-janitor — config-driven transcript and session hygiene
# Reads config.json for gateway locations, thresholds, and features.
set -euo pipefail

export PATH="/home/${USER:-$(whoami)}/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"
CONFIG_FILE="$SKILL_DIR/config.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: $CONFIG_FILE not found — run setup.sh first"
    exit 1
fi

# --- Load config ---
read_config() {
    python3 -c "import json,sys; c=json.load(open('$CONFIG_FILE')); exec(sys.stdin.read())" <<PYEOF
import os
vals = {
    'TRIM_MAX_KB': c.get('trimMaxKB', 250),
    'KEEP_PAIRS': c.get('keepPairs', 10),
    'KEEP_FULL_PAIRS': c.get('keepFullPairs', 2),
    'ARCHIVE_RETENTION_DAYS': c.get('archiveRetentionDays', 7),
    'ORPHAN_GRACE_MINUTES': c.get('orphanGraceMinutes', 30),
    'STALE_SUBAGENT_HOURS': c.get('staleSubagentHours', 24),
    'STALE_CRON_SESSION_HOURS': c.get('staleCronSessionHours', 24),
    'LLM_ENABLED': str(c.get('llmExtraction',{}).get('enabled', False)).lower(),
    'LLM_MAX_PER_RUN': c.get('llmExtraction',{}).get('maxPerRun', 1),
    'LLM_GATEWAY': c.get('llmExtraction',{}).get('gateway', ''),
    'MEM_ENABLED': str(c.get('memCli',{}).get('enabled', False)).lower(),
    'MEM_PATH': c.get('memCli',{}).get('path', 'mem'),
    'STATE_FILE': os.path.expanduser(c.get('stateFile', '~/.openclaw/session-janitor-state.json')),
    'GATEWAY_COUNT': len(c.get('gateways', [])),
}
for k, v in vals.items():
    print(f'{k}={v}')
PYEOF
}

eval "$(read_config)"

# Gateway details
get_gateway() {
    local idx="$1" field="$2"
    python3 -c "
import json, os
c = json.load(open('$CONFIG_FILE'))
gw = c['gateways'][$idx]
v = gw.get('$field', '')
if isinstance(v, str) and '~' in v:
    v = os.path.expanduser(v)
print(v)
"
}

LLM_EXTRACTIONS_THIS_RUN=0

# Resolve LLM gateway port/token (prefer llmExtraction.gateway name, fall back to first gateway)
get_llm_gateway_field() {
    local field="$1"
    python3 -c "
import json, os
c = json.load(open('$CONFIG_FILE'))
gws = c.get('gateways', [])
pref = c.get('llmExtraction', {}).get('gateway', '')
gw = next((g for g in gws if g.get('name') == pref), gws[0] if gws else {})
v = gw.get('$field', '')
if isinstance(v, str) and '~' in v: v = os.path.expanduser(v)
print(v)
"
}

LLM_PORT=$(get_llm_gateway_field port)
LLM_TOKEN=$(get_llm_gateway_field token)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- Process one gateway ---
process_gateway() {
    local idx="$1"
    local name port token sessions_dir sessions_json
    name=$(get_gateway "$idx" "name")
    port=$(get_gateway "$idx" "port")
    token=$(get_gateway "$idx" "token")
    sessions_dir=$(get_gateway "$idx" "sessionsDir")
    sessions_json="$sessions_dir/sessions.json"

    if [[ ! -f "$sessions_json" ]]; then
        log "$name: no sessions.json — skipping"
        return
    fi

    # Get active session IDs
    local active_sids
    active_sids=$(python3 -c "
import json
d = json.load(open('$sessions_json'))
for v in d.get('sessions', d).values():
    sid = v.get('sessionId', '')
    if sid: print(sid)
" 2>/dev/null)

    local orphan_count=0 archive_rm_count=0 reset_count=0

    shopt -s nullglob
    for jsonl in "$sessions_dir"/*.jsonl; do
        [[ "$jsonl" == *".reset."* ]] && continue
        [[ "$jsonl" == *".deleted."* ]] && continue
        [[ "$jsonl" == *".pre-trim."* ]] && continue

        local sid size_kb
        sid=$(basename "$jsonl" .jsonl)
        size_kb=$(( $(stat -c%s "$jsonl" 2>/dev/null || echo 0) / 1024 ))

        if echo "$active_sids" | grep -qF "$sid"; then
            # ACTIVE session — trim if oversized
            if (( size_kb > TRIM_MAX_KB )); then
                log "$name: active transcript $sid is ${size_kb}KB — trimming to last $KEEP_PAIRS pairs"
                if python3 "$SCRIPTS_DIR/trim.py" "$jsonl" "$sid" "$name" "$STATE_FILE" "$KEEP_PAIRS" "$KEEP_FULL_PAIRS" 2>&1; then
                    reset_count=$((reset_count + 1))

                    # LLM extraction of archived content
                    if [[ "$LLM_ENABLED" == "true" ]] && (( LLM_EXTRACTIONS_THIS_RUN < LLM_MAX_PER_RUN )); then
                        local pre_trim_file
                        pre_trim_file=$(ls -t "${jsonl}.pre-trim."* 2>/dev/null | head -1)
                        if [[ -n "$pre_trim_file" ]]; then
                            local llm_api_url="http://127.0.0.1:${LLM_PORT}"
                            if python3 "$SCRIPTS_DIR/extract-llm.py" \
                                "$pre_trim_file" "$jsonl" "$sid" "$name" "$STATE_FILE" \
                                "$llm_api_url" "$LLM_TOKEN" "$MEM_ENABLED" "$MEM_PATH" 2>&1; then
                                log "$name: LLM extraction complete for $sid"
                                LLM_EXTRACTIONS_THIS_RUN=$((LLM_EXTRACTIONS_THIS_RUN + 1))
                            else
                                local exit_code=$?
                                if [[ $exit_code -eq 2 ]]; then
                                    log "$name: LLM extraction failed for $sid"
                                else
                                    log "$name: LLM extraction skipped for $sid (dedup/lock/insufficient)"
                                fi
                            fi
                        fi
                    fi

                    # Notify the gateway to reload the trimmed transcript
                    if [[ -n "$token" ]]; then
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
                                -d '{"model":"openclaw","messages":[{"role":"user","content":"[session trimmed by maintenance — acknowledge with NO_REPLY]"}]}' \
                                >/dev/null 2>&1 || true
                        fi
                    fi
                else
                    log "$name: trim failed for $sid"
                fi
            fi
        else
            # ORPHAN — grace period then archive
            local mod_min
            mod_min=$(( ( $(date +%s) - $(stat -c%Y "$jsonl" 2>/dev/null || echo 0) ) / 60 ))
            if (( mod_min < ORPHAN_GRACE_MINUTES )); then
                continue
            fi
            mv "$jsonl" "${jsonl}.reset.$(date -u +%Y-%m-%dT%H-%M-%SZ)"
            orphan_count=$((orphan_count + 1))
        fi
    done
    shopt -u nullglob

    # --- Prune stale session entries ---
    local pruned_count
    pruned_count=$(python3 "$SCRIPTS_DIR/prune-sessions.py" "$sessions_json" "$STALE_SUBAGENT_HOURS" "$STALE_CRON_SESSION_HOURS")

    # --- Remove old archives ---
    while IFS= read -r archive; do
        rm -f "$archive"
        archive_rm_count=$((archive_rm_count + 1))
    done < <(find "$sessions_dir" -maxdepth 1 \( -name "*.reset.*" -o -name "*.deleted.*" -o -name "*.pre-trim.*" \) -mtime +${ARCHIVE_RETENTION_DAYS} 2>/dev/null)

    # --- Report ---
    local changes=0
    (( reset_count > 0 )) && { log "$name: trimmed $reset_count transcript(s)"; changes=1; }
    (( orphan_count > 0 )) && { log "$name: archived $orphan_count orphan(s)"; changes=1; }
    (( pruned_count > 0 )) && { log "$name: pruned $pruned_count stale session entries"; changes=1; }
    (( archive_rm_count > 0 )) && { log "$name: removed $archive_rm_count old archives"; changes=1; }
    (( changes == 0 )) && log "$name: clean" || true
}

# --- Main ---
for (( i=0; i<GATEWAY_COUNT; i++ )); do
    process_gateway "$i"
done

log "Done"
