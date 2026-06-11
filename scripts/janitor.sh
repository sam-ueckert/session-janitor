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
    'MIN_ARCHIVE_PAIRS': c.get('minArchivePairs', 5),
    'TRIM_FULL_THRESHOLD_PCT': c.get('trimFullThresholdPct', 50),
    'ARCHIVE_RETENTION_DAYS': c.get('archiveRetentionDays', 7),
    'KEEP_PRE_TRIM_FILES': c.get('keepPreTrimFiles', 3),
    'ORPHAN_GRACE_MINUTES': c.get('orphanGraceMinutes', 30),
    'STALE_SUBAGENT_HOURS': c.get('staleSubagentHours', 24),
    'STALE_CRON_SESSION_HOURS': c.get('staleCronSessionHours', 24),
    'LLM_ENABLED': str(c.get('llmExtraction',{}).get('enabled', False)).lower(),
    'LLM_MAX_PER_RUN': c.get('llmExtraction',{}).get('maxPerRun', 1),
    'LLM_GATEWAY': c.get('llmExtraction',{}).get('gateway', ''),
    'LLM_MODEL': c.get('llmExtraction',{}).get('model', 'openclaw'),
    'LLM_MAX_INPUT_CHARS': c.get('llmExtraction',{}).get('maxInputChars', 20000),
    'LLM_TIMEOUT_SECS': c.get('llmExtraction',{}).get('timeoutSecs', 60),
    'LLM_MAX_MEMORIES': c.get('llmExtraction',{}).get('maxMemories', 15),
    'LLM_MIN_ARCHIVED': c.get('llmExtraction',{}).get('minArchived', 3),
    'MEM_ENABLED': str(c.get('memCli',{}).get('enabled', False)).lower(),
    'MEM_PATH': c.get('memCli',{}).get('path', 'mem'),
    'MEM_BACKEND_TYPE': c.get('memBackend',{}).get('type',''),
    'MEM_BACKEND_WEBHOOK_URL': c.get('memBackend',{}).get('webhookUrl',''),
    'MEM_BACKEND_WEBHOOK_HEADERS': json.dumps(c.get('memBackend',{}).get('webhookHeaders',{})),
    'SCENE_FILES_PATH': os.path.expanduser(c.get('sceneFilesPath', '')),
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
        [[ "$jsonl" == *".trajectory."* ]] && continue  # OC runtime telemetry, not a transcript

        local sid size_kb
        sid=$(basename "$jsonl" .jsonl)
        size_kb=$(( $(stat -c%s "$jsonl" 2>/dev/null || echo 0) / 1024 ))

        if echo "$active_sids" | grep -qF "$sid"; then
            # ACTIVE session — always clear modelOverride + compactionCheckpoints regardless of size
            python3 -c "
import json
path = '$sessions_json'
sid = '$sid'
d = json.load(open(path))
sessions = d.get('sessions', d)
changed = False
for k, v in sessions.items():
    if v.get('sessionId') == sid:
        if 'compactionCheckpoints' in v:
            del v['compactionCheckpoints']
            changed = True
        if 'modelOverride' in v:
            del v['modelOverride']
            changed = True
if changed:
    json.dump(d, open(path, 'w'), indent=2)
    print('cleared')
" 2>/dev/null | grep -q cleared && log "$name: cleared modelOverride/compactionCheckpoints for $sid" || true

            # Active-session trim is handled by the session-janitor OC plugin
            # (before_agent_finalize hook). The janitor script now only handles
            # orphan sessions and housekeeping that requires cross-session views.
        else
            # ORPHAN — grace period then archive
            local mod_min
            mod_min=$(( ( $(date +%s) - $(stat -c%Y "$jsonl" 2>/dev/null || echo 0) ) / 60 ))
            if (( mod_min < ORPHAN_GRACE_MINUTES )); then
                continue
            fi

            # LLM extraction of orphan session before archiving
            if [[ "$LLM_ENABLED" == "true" ]]; then
                if (( LLM_EXTRACTIONS_THIS_RUN < LLM_MAX_PER_RUN )); then
                    local llm_api_url="http://127.0.0.1:${LLM_PORT}"
                    if python3 "$SCRIPTS_DIR/extract.py" transcript \
                        "$jsonl" \
                        --sid "$sid" \
                        --state "$STATE_FILE" \
                        --api-url "$llm_api_url" --api-token "$LLM_TOKEN" \
                        $([ "$MEM_ENABLED" = "true" ] && echo "--mem-enabled") \
                        --mem-path "$MEM_PATH" \
                        --mem-backend "$MEM_BACKEND_TYPE" \
                        --webhook-url "$MEM_BACKEND_WEBHOOK_URL" \
                        --webhook-headers-json "$MEM_BACKEND_WEBHOOK_HEADERS" \
                        --scene-dir "$SCENE_FILES_PATH" \
                        --model "$LLM_MODEL" \
                        --max-chars "$LLM_MAX_INPUT_CHARS" \
                        --timeout "$LLM_TIMEOUT_SECS" \
                        --max-memories "$LLM_MAX_MEMORIES" \
                        --min-archived "$LLM_MIN_ARCHIVED" 2>&1; then
                        log "$name: LLM extraction complete for orphan $sid"
                        LLM_EXTRACTIONS_THIS_RUN=$((LLM_EXTRACTIONS_THIS_RUN + 1))
                    else
                        local exit_code=$?
                        if [[ $exit_code -eq 2 ]]; then
                            log "ERROR: $name: LLM extraction FAILED for orphan $sid"
                        else
                            log "$name: LLM extraction skipped for orphan $sid (dedup/lock/insufficient)"
                        fi
                    fi
                else
                    log "WARNING: $name: LLM extraction RATE-LIMITED for orphan $sid (maxPerRun=${LLM_MAX_PER_RUN} reached)"
                fi
            fi

            mv "$jsonl" "${jsonl}.reset.$(date -u +%Y-%m-%dT%H-%M-%SZ)"
            orphan_count=$((orphan_count + 1))
        fi
    done
    shopt -u nullglob

    # --- Prune compaction checkpoints from all active sessions ---
    local checkpoint_pruned
    checkpoint_pruned=$(python3 -c "
import json
path = '$sessions_json'
d = json.load(open(path))
sessions = d.get('sessions', d)
count = 0
for k, v in sessions.items():
    if 'compactionCheckpoints' in v:
        del v['compactionCheckpoints']
        count += 1
if count:
    json.dump(d, open(path, 'w'), indent=2)
print(count)
" 2>/dev/null || echo 0)
    (( checkpoint_pruned > 0 )) && log "$name: pruned compaction checkpoints from $checkpoint_pruned session(s)"

    # --- Pointer-orphan cleanup: sessions.json entries with no backing JSONL ---
    # These cause gateway errors on the next message to that session.
    local ptr_orphan_sids ptr_orphan_count=0
    ptr_orphan_sids=$(python3 - "$sessions_json" "$sessions_dir" <<'PYEOF'
import json, os, sys, shutil
path = sys.argv[1]
sessions_dir = sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(0)
sessions = d.get('sessions', d)
to_del = []
for key, v in sessions.items():
    sid = v.get('sessionId', '')
    if not sid:
        continue
    jsonl = os.path.join(sessions_dir, sid + '.jsonl')
    if not os.path.exists(jsonl):
        to_del.append((key, sid))
for key, sid in to_del:
    del sessions[key]
    print(sid)
if to_del:
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(d, f, indent=2)
    shutil.move(tmp, path)
PYEOF
)
    if [[ -n "$ptr_orphan_sids" ]]; then
        while IFS= read -r ptr_sid; do
            [[ -z "$ptr_sid" ]] && continue
            log "$name: removed pointer-orphan session entry: $ptr_sid (no backing JSONL)"
            ptr_orphan_count=$((ptr_orphan_count + 1))
        done <<< "$ptr_orphan_sids"
        log "$name: total pointer-orphan entries removed: $ptr_orphan_count"
    fi

    # --- Prune stale session entries ---
    local pruned_count
    pruned_count=$(python3 "$SCRIPTS_DIR/prune-sessions.py" "$sessions_json" "$STALE_SUBAGENT_HOURS" "$STALE_CRON_SESSION_HOURS")

    # --- Per-session pre-trim cap: keep only the N most recent, delete the rest immediately ---
    shopt -s nullglob
    declare -A seen_bases
    for pt in "$sessions_dir"/*.jsonl.pre-trim.*; do
        base=$(echo "$pt" | sed 's|\.jsonl\.pre-trim\..*||')
        seen_bases["$base"]=1
    done
    for base in "${!seen_bases[@]}"; do
        mapfile -t pts < <(ls -t "${base}.jsonl.pre-trim."* 2>/dev/null)
        if (( ${#pts[@]} > KEEP_PRE_TRIM_FILES )); then
            excess=("${pts[@]:$KEEP_PRE_TRIM_FILES}")
            for f in "${excess[@]}"; do
                rm -f "$f"
                archive_rm_count=$((archive_rm_count + 1))
            done
        fi
    done
    unset seen_bases
    shopt -u nullglob

    # --- Remove old archives (all known patterns) ---
    while IFS= read -r archive; do
        rm -f "$archive"
        archive_rm_count=$((archive_rm_count + 1))
    done < <(find "$sessions_dir" -maxdepth 1 \
        \( -name "*.reset.*" -o -name "*.deleted.*" -o -name "*.pre-trim.*" \
           -o -name "*.bak-*" -o -name "*.purged.*" -o -name "*.emergency-*" \) \
        -mtime +${ARCHIVE_RETENTION_DAYS} 2>/dev/null)

    # --- Orphan checkpoint cleanup ---
    # Checkpoint files (*.checkpoint.*.jsonl) are created by auto-compaction.
    # Remove them when their parent session no longer has an active .jsonl,
    # or when they are older than archiveRetentionDays.
    shopt -s nullglob
    local cp_rm_count=0
    for cpf in "$sessions_dir"/*.checkpoint.*.jsonl; do
        [[ -f "$cpf" ]] || continue
        # Extract the session ID (everything before .checkpoint.)
        local cp_sid
        cp_sid=$(basename "$cpf" | sed 's|\.checkpoint\..*||')
        # If the active transcript still exists, skip (compaction may be in flight)
        if [[ -f "$sessions_dir/${cp_sid}.jsonl" ]]; then
            # Only delete if it's older than retention (gives in-flight compaction plenty of time)
            local cp_age_days
            cp_age_days=$(( ( $(date +%s) - $(stat -c%Y "$cpf" 2>/dev/null || echo 0) ) / 86400 ))
            (( cp_age_days < ARCHIVE_RETENTION_DAYS )) && continue
        fi
        rm -f "$cpf"
        cp_rm_count=$((cp_rm_count + 1))
        log "$name: removed orphaned checkpoint for $cp_sid"
    done
    shopt -u nullglob
    (( cp_rm_count > 0 )) && { archive_rm_count=$((archive_rm_count + cp_rm_count)); }

    # --- Orphan toolcache cleanup ---
    # Remove .toolcache/ dirs whose session is dead (no active .jsonl) and old enough
    shopt -s nullglob
    local tc_rm_count=0
    for tc in "$sessions_dir"/*.toolcache; do
        [[ -d "$tc" ]] || continue
        local tc_sid
        tc_sid=$(basename "$tc" .toolcache)
        # Skip if active transcript exists
        [[ -f "$sessions_dir/${tc_sid}.jsonl" ]] && continue
        # Skip if the toolcache itself is too fresh (within orphan grace)
        local tc_age_min
        tc_age_min=$(( ( $(date +%s) - $(stat -c%Y "$tc" 2>/dev/null || echo 0) ) / 60 ))
        (( tc_age_min < ORPHAN_GRACE_MINUTES )) && continue
        rm -rf "$tc"
        tc_rm_count=$((tc_rm_count + 1))
        log "$name: removed orphan toolcache ${tc_sid}"
    done
    shopt -u nullglob
    (( tc_rm_count > 0 )) && { archive_rm_count=$((archive_rm_count + tc_rm_count)); }

    # --- Report ---
    local changes=0
    (( reset_count > 0 )) && { log "$name: trimmed $reset_count transcript(s)"; changes=1; }
    (( orphan_count > 0 )) && { log "$name: archived $orphan_count orphan(s)"; changes=1; }
    (( pruned_count > 0 )) && { log "$name: pruned $pruned_count stale session entries"; changes=1; }
    (( archive_rm_count > 0 )) && { log "$name: removed $archive_rm_count old archives"; changes=1; }
    (( changes == 0 )) && log "$name: clean" || true
}

# --- Watchdog ---
run_watchdog() {
    local enabled stale_min
    enabled=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(str(c.get('watchdog',{}).get('enabled',False)).lower())" 2>/dev/null || echo false)
    [[ "$enabled" != "true" ]] && return
    stale_min=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('watchdog',{}).get('staleMinutes',5))" 2>/dev/null || echo 5)
    log "running watchdog (stale threshold: ${stale_min}min)"
    bash "$SCRIPTS_DIR/watchdog.sh" "$stale_min" "$STATE_FILE" 2>&1 || log "watchdog exited non-zero"
}

# --- Main ---
for (( i=0; i<GATEWAY_COUNT; i++ )); do
    process_gateway "$i"
done

run_watchdog

log "Done"
