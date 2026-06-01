#!/usr/bin/env bash
# Test the session-janitor plugin in the local test container.
#
# Tests:
#   1. Plugin installed and enabled (via openclaw plugins list)
#   2. Hook registration (session_start, session_end, before_agent_finalize)
#   3. sidecar.py correctly offloads large tool results
#   4. trim.py correctly trims oversized transcripts
#   5. before_agent_finalize hook integration test (direct script call)
#   6. External sweep processes NOT running (regression: timing race)
#
# Does NOT require a live API key.

set -euo pipefail

CONTAINER="oc-janitor-test"
SESSIONS_DIR="/home/janitor/.openclaw-test/agents/main/sessions"
SCRIPTS_DIR="/home/janitor/session-janitor/scripts"
PASS=0
FAIL=0

red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
blue()  { echo -e "\033[34m$*\033[0m"; }

pass() { echo "  $(green PASS) $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  $(red FAIL) $1: $2"; FAIL=$(( FAIL + 1 )); }

check() {
  local desc="$1" cond="$2"
  if eval "$cond" 2>/dev/null; then pass "$desc"; else fail "$desc" "condition false: $cond"; fi
}

dc() { /Users/ueckerts/.rd/bin/nerdctl exec "$CONTAINER" bash -c "$1" 2>&1; }

section() { echo; blue "── $1 ──"; }

# ── Wait for container ────────────────────────────────────────────────────────
section "Container startup"
for i in $(seq 1 15); do
  if /Users/ueckerts/.rd/bin/nerdctl inspect "$CONTAINER" &>/dev/null; then
    pass "Container '$CONTAINER' is running"
    break
  fi
  sleep 2
  if (( i == 15 )); then fail "Container not found" "run: nerdctl run -d --name $CONTAINER ..."; exit 1; fi
done

# ── Plugin registration ───────────────────────────────────────────────────────
section "Plugin installation and registration"

PLUGIN_INSPECT_FILE=$(mktemp)
dc "env OPENCLAW_STATE_DIR=/home/janitor/.openclaw-test /usr/local/bin/openclaw plugins inspect session-janitor 2>&1" > "$PLUGIN_INSPECT_FILE"
check "session-janitor appears in plugin registry" "grep -qi 'session.janitor' '$PLUGIN_INSPECT_FILE'"
check "session-janitor status is loaded" "grep -qi 'Status: loaded' '$PLUGIN_INSPECT_FILE'"
rm -f "$PLUGIN_INSPECT_FILE"

# Check hooks registered at gateway startup (in container logs)
CONTAINER_LOG_FILE=$(mktemp)
/Users/ueckerts/.rd/bin/nerdctl logs "$CONTAINER" 2>&1 > "$CONTAINER_LOG_FILE"
check "session_start hook registered at startup" "grep -q 'session_start' '$CONTAINER_LOG_FILE'"
check "session_end hook registered at startup" "grep -q 'session_end' '$CONTAINER_LOG_FILE'"
check "before_agent_finalize hook registered at startup" "grep -q 'before_agent_finalize' '$CONTAINER_LOG_FILE'"
check "gateway_start fired confirming runtime load" "grep -q 'GATEWAY_START fired' '$CONTAINER_LOG_FILE'"
rm -f "$CONTAINER_LOG_FILE"

# Verify gateway started with session-janitor in plugin count
GW_STARTUP_LOG=$(/Users/ueckerts/.rd/bin/nerdctl logs "$CONTAINER" 2>&1)
check "Gateway startup includes session-janitor in plugin count" \
  "echo '$GW_STARTUP_LOG' | grep -q 'session-janitor'"

# ── Create test session ───────────────────────────────────────────────────────
section "Test session and transcript setup"

TEST_SID="test-$(date +%s)-$(head -c4 /dev/urandom | xxd -p)"
TEST_JSONL="$SESSIONS_DIR/$TEST_SID.jsonl"

dc "mkdir -p $SESSIONS_DIR"
dc "python3 -c \"
import json, time, uuid, random, string

def rand_id():
    return ''.join(random.choices(string.hexdigits[:16], k=8))

entries = []

# Session header
entries.append({'type': 'session', 'id': '$TEST_SID',
    'timestamp': int(time.time()*1000),
    'message': {'sessionId': '$TEST_SID'}})

# A user/assistant exchange
entries.append({'type': 'message', 'id': rand_id(),
    'timestamp': int(time.time()*1000),
    'message': {'role': 'user', 'content': [{'type': 'text', 'text': 'test'}]}})

entries.append({'type': 'message', 'id': rand_id(),
    'timestamp': int(time.time()*1000),
    'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'test reply'}]}})

# Large toolResult (>512 bytes, triggering sidecar)
large_text = 'X' * 5000  # 5KB text output
entries.append({'type': 'message', 'id': rand_id(),
    'timestamp': int(time.time()*1000),
    'message': {
        'role': 'toolResult',
        'toolCallId': 'call-abc123',
        'toolName': 'exec',
        'content': [{'type': 'text', 'text': large_text}]
    }})

# Write the file
with open('$TEST_JSONL', 'w') as f:
    for e in entries:
        f.write(json.dumps(e) + '\n')

size = len(open('$TEST_JSONL').read())
print(f'Created $TEST_JSONL ({size} bytes, {len(entries)} entries)')
\""

SIZE=$(dc "stat -c%s '$TEST_JSONL' 2>/dev/null || echo 0")
check "Test session JSONL created ($SIZE bytes)" "(( $SIZE > 512 ))"

# ── Sidecar test ──────────────────────────────────────────────────────────────
section "sidecar.py: large tool output offloading"

SIDECAR_OUT=$(dc "python3 $SCRIPTS_DIR/sidecar.py '$TEST_JSONL' '$TEST_SID' 512 2>&1")
echo "  sidecar output: $(echo "$SIDECAR_OUT" | tail -1)"

TOOLCACHE_DIR="$SESSIONS_DIR/$TEST_SID.toolcache"
check "toolcache directory created" "dc 'ls -d $TOOLCACHE_DIR 2>/dev/null' | grep -q toolcache"

TOOLCACHE_FILES=$(dc "ls '$TOOLCACHE_DIR' 2>/dev/null")
check "sidecar file written to toolcache" "[[ -n '$TOOLCACHE_FILES' ]]"

SIZE_AFTER_SIDECAR=$(dc "stat -c%s '$TEST_JSONL' 2>/dev/null || echo 99999")
check "JSONL shrunk after sidecar ($SIZE → $SIZE_AFTER_SIDECAR bytes)" "(( $SIZE_AFTER_SIDECAR < $SIZE ))"

STUB_IN_JSONL=$(dc "grep -c 'offloaded to' '$TEST_JSONL' 2>/dev/null || echo 0")
check "Stub pointer written in JSONL ($STUB_IN_JSONL stubs)" "(( $STUB_IN_JSONL > 0 ))"

# ── Trim test ─────────────────────────────────────────────────────────────────
section "trim.py: transcript size reduction"

# Add more entries to push over 5KB trim threshold
dc "python3 -c \"
import json, time, random, string

def rand_id():
    return ''.join(random.choices(string.hexdigits[:16], k=8))

# Add many user/assistant pairs to bloat the file
new_entries = []
for i in range(30):
    new_entries.append({'type': 'message', 'id': rand_id(),
        'timestamp': int(time.time()*1000) + i*1000,
        'message': {'role': 'user', 'content': [{'type': 'text', 'text': f'message {i} ' + 'Y'*200}]}})
    new_entries.append({'type': 'message', 'id': rand_id(),
        'timestamp': int(time.time()*1000) + i*1000 + 500,
        'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': f'reply {i} ' + 'Z'*200}]}})

with open('$TEST_JSONL', 'a') as f:
    for e in new_entries:
        f.write(json.dumps(e) + '\n')
size = len(open('$TEST_JSONL').read())
print(f'Padded to {size} bytes')
\""

SIZE_BEFORE_TRIM=$(dc "stat -c%s '$TEST_JSONL' 2>/dev/null || echo 0")
echo "  File size before trim: ${SIZE_BEFORE_TRIM} bytes"

TRIM_OUT=$(dc "python3 $SCRIPTS_DIR/trim.py '$TEST_JSONL' '$TEST_SID' test /tmp/janitor-state.json 3 1 1 50 5 2>&1")
echo "  trim output: $(echo "$TRIM_OUT" | tail -2 | head -1)"

SIZE_AFTER_TRIM=$(dc "stat -c%s '$TEST_JSONL' 2>/dev/null || echo 99999")
echo "  File size after trim: ${SIZE_AFTER_TRIM} bytes"

check "trim.py reduced file size ($SIZE_BEFORE_TRIM → $SIZE_AFTER_TRIM bytes)" "(( $SIZE_AFTER_TRIM < $SIZE_BEFORE_TRIM ))"
check "trim.py kept file under 5KB threshold (5120 bytes)" "(( $SIZE_AFTER_TRIM < 5120 ))"

PRE_TRIM_COUNT=$(dc "ls '$SESSIONS_DIR'/${TEST_SID}.jsonl.pre-trim.* 2>/dev/null | wc -l | tr -d ' '")
check ".pre-trim. archive file created ($PRE_TRIM_COUNT files)" "(( $PRE_TRIM_COUNT > 0 ))"

# ── Plugin before_agent_finalize integration test ─────────────────────────────
section "before_agent_finalize hook: integration (script-level)"

# Simulate what before_agent_finalize does: sidecar + trim combined
# Create a fresh oversized session
SID2="test2-$(date +%s)"
JSONL2="$SESSIONS_DIR/$SID2.jsonl"

dc "python3 -c \"
import json, time, random, string

def r():
    return ''.join(random.choices(string.hexdigits[:16], k=8))

entries = [
    {'type': 'session', 'id': '$SID2', 'timestamp': int(time.time()*1000),
     'message': {'sessionId': '$SID2'}}
]

# Large tool result + many pairs = definitely over 5KB threshold
for i in range(20):
    entries.append({'type': 'message', 'id': r(), 'timestamp': int(time.time()*1000)+i*1000,
        'message': {'role': 'user', 'content': [{'type': 'text', 'text': f'msg{i} '+'A'*300}]}})
    entries.append({'type': 'message', 'id': r(), 'timestamp': int(time.time()*1000)+i*1000+100,
        'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': f'reply{i} '+'B'*300}]}})
entries.append({'type': 'message', 'id': r(), 'timestamp': int(time.time()*1000),
    'message': {'role': 'toolResult', 'toolCallId': 'call-xyz', 'toolName': 'exec',
                'content': [{'type': 'text', 'text': 'X'*3000}]}})

with open('$JSONL2', 'w') as f:
    for e in entries:
        f.write(json.dumps(e) + '\n')
sz = len(open('$JSONL2').read())
print(f'Created {sz} bytes')
\""

SIZE2_BEFORE=$(dc "stat -c%s '$JSONL2' 2>/dev/null || echo 0")
check "Integration test file over 5KB ($SIZE2_BEFORE bytes)" "(( $SIZE2_BEFORE > 5120 ))"

# Run sidecar then trim (what before_agent_finalize does internally)
dc "python3 $SCRIPTS_DIR/sidecar.py '$JSONL2' '$SID2' 512 2>&1" >/dev/null
dc "python3 $SCRIPTS_DIR/trim.py '$JSONL2' '$SID2' test /tmp/janitor-state.json 3 1 1 50 5 2>&1" >/dev/null

SIZE2_AFTER=$(dc "stat -c%s '$JSONL2' 2>/dev/null || echo 99999")
check "Combined sidecar+trim reduced file ($SIZE2_BEFORE → $SIZE2_AFTER bytes)" "(( $SIZE2_AFTER < $SIZE2_BEFORE ))"
check "File under threshold after combined sidecar+trim" "(( $SIZE2_AFTER < 5120 ))"

# ── Race regression: no external sweeps ──────────────────────────────────────
section "Regression: no external timing sweep processes"

check "watcher.sh not running" "! dc 'pgrep -f watcher.sh' | grep -q '[0-9]'"
check "cron-sweep.sh not running" "! dc 'pgrep -f cron-sweep.sh' | grep -q '[0-9]'"
check "inotifywait not running" "! dc 'pgrep -x inotifywait' | grep -q '[0-9]'"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "────────────────────────────────────────"
if (( FAIL == 0 )); then
  green "All $PASS tests passed"
  echo
  green "Plugin installed, hooks registered, sidecar+trim verified."
  echo "Deploy to swabby-ts: openclaw plugins install --dangerously-force-unsafe-install --link <plugin-path>"
else
  red "$FAIL of $((PASS + FAIL)) tests FAILED"
  exit 1
fi
