# Session Janitor — Architecture & Trimming Deep Dive

## Overview

Session Janitor is a transcript hygiene system for OpenClaw gateways. It reduces context token usage by aggressively trimming JSONL session files while preserving enough history for the agent to remain coherent.

Two complementary triggers:
- **Cron (janitor.sh)** — runs every 15 minutes as a sweep across all sessions
- **Watcher (watcher.sh)** — `inotifywait` fires trim within ~3 seconds of any turn completing

---

## How Trimming Works

### What's in a Session File

Each JSONL file (`~/.openclaw*/agents/main/sessions/<uuid>.jsonl`) contains one JSON object per line:

| Type | Description |
|------|-------------|
| `session` | Header — session ID, metadata (one per file, always first) |
| `message` (user) | User message with text content |
| `message` (assistant) | Assistant response with text + tool calls |
| `message` (toolResult) | Output from tool executions |
| `compaction` | Summary stub inserted by trim or gateway compaction |

### What Gets Stripped

**Thinking blocks** (from `assistant` messages, non-recent turns):
```json
{ "type": "thinking", "thinking": "...57KB of internal reasoning...", "thinkingSignature": "..." }
```
→ Dropped entirely. The model doesn't need its old reasoning chain.

**toolCall arguments** (from `assistant` messages, non-recent turns):
```json
{ "type": "toolCall", "id": "abc123", "name": "exec", "arguments": "{\"command\":\"...long script...\"}" }
```
→ Reduced to `{ "type": "toolCall", "id": "abc123", "name": "exec" }`. The name is sufficient for context; the gateway doesn't need to re-read old arguments.

**toolResult bodies** (all but the most recent `keepFullPairs` assistant turns, default 2):
Full tool output entries (often 5-50KB each) are collapsed into a single summary line per turn:
```
exec ✓(0): first line of output | Read ✓(0) | exec ✗(1): error text
```

### What's Preserved

- **Session header** — always kept (required by gateway)
- **Last N user/assistant pairs** (default: 10) — kept verbatim
- **Recent 2 assistant turns** — full toolResult entries preserved
- **Synthetic compaction entry** — describes what was archived and why

### Size Reduction Examples

| Session | Before | After | Reduction |
|---------|--------|-------|-----------|
| Heavy tool use + extended thinking | 401KB | 91KB | 77% |
| Normal conversation | 266KB | 100KB | 62% |
| Moderate tool use | 316KB | 102KB | 68% |
| Post-trim steady state | 157KB | 91KB | 42% |

### Token Math

Raw JSONL → tokens is roughly 4 chars/token, but JSON overhead makes it worse.

| Component | Approx tokens |
|-----------|--------------|
| System prompt + tool schemas | ~20–25k |
| Injected workspace files (SOUL, MEMORY, AGENTS, etc.) | ~5–8k |
| Total overhead before transcript | ~28–33k |
| Remaining budget (80k limit) | ~47–52k |
| 150KB trimmed transcript | ~12–15k |
| **Total at steady state** | **~40–45k / 80k** |

Before trimming, sessions routinely exceeded 80k tokens, triggering gateway compaction. After trimming, steady-state context stays around 40–45k.

---

## The Two Triggers

### Cron (every 15 min)

`janitor.sh` sweeps all active sessions across all gateways. Also runs:
- LLM memory extraction (extracts structured facts/decisions from archived content)
- Stale session pruning (removes orphan subagent entries)
- Archive cleanup (deletes `.pre-trim.*` files older than 7 days)

### Watcher (per-turn, ~3s latency)

`watcher.sh` uses an OS-appropriate file watcher:
- *Linux:* `inotifywait` in monitor mode (`inotify-tools` package)
- *macOS:* `fswatch` with FSEvents backend (`brew install fswatch`)

Both output one absolute path per line on write events. The rest of the flow is identical.

Flow per JSONL write event:
1. JSONL file closes after a turn completes
2. inotifywait/fswatch emits the event
3. 3-second debounce (waits for follow-on writes to finish)
4. Check file size — if over threshold (150KB), proceed
5. Verify it's an active session (check sessions.json)
6. Run `trim.py` in background
7. Ping gateway via Chat Completions API with `x-openclaw-session-key` to force in-memory reload

The reload ping is critical — without it the gateway keeps its old in-memory context until the next session load.

---

## Gateway Reload Mechanism

After trim, the watcher sends a no-op message to the gateway:

```bash
curl http://127.0.0.1:<port>/v1/chat/completions \
  -H "Authorization: Bearer <token>" \
  -H "x-openclaw-session-key: <session-key>" \
  -d '{"model":"openclaw","messages":[{"role":"user","content":"[session trimmed by maintenance — acknowledge with NO_REPLY]"}]}'
```

The `x-openclaw-session-key` header routes the request to the specific session. The gateway re-reads the JSONL file from disk before processing, so the trimmed context becomes active immediately.

The agent acknowledges with `NO_REPLY` (a special token instructing it not to send a visible reply).

---

## File Layout

```
skills/session-janitor/
├── SKILL.md                          # Agent instructions
├── ARCHITECTURE.md                   # This file
├── config.json                       # Generated by setup (gitignored)
├── config.example.json               # Reference config
├── session-janitor-watcher.service   # Systemd user service template
└── scripts/
    ├── setup.sh          # Gateway discovery, config gen, cron + service install
    ├── janitor.sh        # Cron entry point (trim + extract + prune)
    ├── trim.py           # Core transcript trimming logic
    ├── extract-llm.py    # LLM memory extraction from archived content
    ├── prune-sessions.py # Stale subagent/cron session pruning
    └── watcher.sh        # inotifywait per-turn trigger
```

---

## Operational Notes

- `trim.py` archives the original as `<uuid>.jsonl.pre-trim.<timestamp>` before writing
- Archives are cleaned up after 7 days (configurable via `archiveRetentionDays`)
- The watcher service restarts automatically on failure (`Restart=on-failure`)
- Watcher log: `/tmp/session-janitor-watcher.log`
- Cron log: `/tmp/session-janitor.log`
- State (dedup tracking): `~/.openclaw/session-janitor-state.json`
