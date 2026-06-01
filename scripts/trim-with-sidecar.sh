#!/usr/bin/env bash
# trim-with-sidecar.sh — spawned detached by the OC plugin's agent_end hook.
# Runs sidecar offload then trim on an oversized session transcript.
# Called AFTER OC has released the session, so no takeover risk.
#
# Args:
#   $1  transcript path (JSONL)
#   $2  session id
#   $3  gateway name
#   $4  state file path
#   $5  keep_pairs
#   $6  keep_full_pairs
#   $7  min_archive_pairs
#   $8  trim_full_threshold_pct
#   $9  trim_max_kb
#   $10 sidecar_min_bytes (0 = disabled)

set -euo pipefail
export PATH="/home/${USER:-$(whoami)}/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

JSONL="$1"
SID="$2"
GATEWAY="$3"
STATE_FILE="$4"
KEEP_PAIRS="$5"
KEEP_FULL_PAIRS="$6"
MIN_ARCHIVE_PAIRS="$7"
TRIM_FULL_PCT="$8"
TRIM_MAX_KB="$9"
SIDECAR_MIN_BYTES="${10:-0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="/tmp/session-janitor-plugin.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [plugin-trim] $*" >> "$LOG" 2>/dev/null || true; }

[[ -f "$JSONL" ]] || exit 0

SIZE_BEFORE=$(( $(stat -c%s "$JSONL" 2>/dev/null || echo 0) / 1024 ))
log "$GATEWAY: $SID (${SIZE_BEFORE}KB) — starting sidecar+trim"

# Guard: verify last entry is cache-ttl before modifying (OC may have started
# a new turn since agent_end fired).
LAST_TYPE=$(python3 -c "
import json, sys
try:
    entries = [json.loads(l) for l in open('$JSONL') if l.strip()]
    last = entries[-1] if entries else {}
    if last.get('type') == 'custom' and last.get('customType') == 'openclaw.cache-ttl':
        print('ok')
    elif last.get('type') == 'message' and last.get('message', {}).get('role') == 'user':
        print('midturn')
    else:
        print('ok')
except Exception:
    print('ok')
" 2>/dev/null)

if [[ "$LAST_TYPE" == "midturn" ]]; then
    log "$GATEWAY: $SID — new turn started, skipping trim"
    exit 0
fi

# Sidecar
if (( SIDECAR_MIN_BYTES > 0 )); then
    python3 "$SCRIPT_DIR/sidecar.py" "$JSONL" "$SID" "$SIDECAR_MIN_BYTES" >> "$LOG" 2>&1 || true
fi

SIZE_AFTER_SIDECAR=$(( $(stat -c%s "$JSONL" 2>/dev/null || echo 0) / 1024 ))
if (( SIZE_AFTER_SIDECAR <= TRIM_MAX_KB )); then
    log "$GATEWAY: $SID — ${SIZE_BEFORE}KB → ${SIZE_AFTER_SIDECAR}KB (sidecar only)"
    exit 0
fi

# Trim
python3 "$SCRIPT_DIR/trim.py" \
    "$JSONL" "$SID" "$GATEWAY" "$STATE_FILE" \
    "$KEEP_PAIRS" "$KEEP_FULL_PAIRS" "$MIN_ARCHIVE_PAIRS" \
    "$TRIM_FULL_PCT" "$TRIM_MAX_KB" >> "$LOG" 2>&1 || true

SIZE_AFTER=$(( $(stat -c%s "$JSONL" 2>/dev/null || echo 0) / 1024 ))
log "$GATEWAY: $SID — ${SIZE_BEFORE}KB → ${SIZE_AFTER}KB (done)"
