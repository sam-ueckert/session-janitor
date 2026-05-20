#!/usr/bin/env python3
"""Unified LLM-powered memory extraction.

Handles both JSONL session transcripts and plain markdown notes files.

Usage (transcript mode):
  extract.py transcript <pre_trim> [--trimmed <trimmed>] --sid <id> \\
    --state <file> --api-url <url> --api-token <token> \\
    [--mem-enabled] [--mem-path <path>] [--scene-dir <dir>] \\
    [--model <m>] [--max-chars N] [--timeout N] [--max-memories N] [--min-archived N]

Usage (markdown mode):
  extract.py markdown <file.md> \\
    --state <file> --api-url <url> --api-token <token> \\
    [--mem-enabled] [--mem-path <path>] [--scene-dir <dir>] \\
    [--model <m>] [--max-chars N] [--timeout N] [--max-memories N]

Exit codes: 0=success, 1=skipped (dedup/insufficient), 2=LLM failure
"""
import argparse, json, sys, os, subprocess, fcntl, signal, glob
from datetime import datetime, date

LOCKFILE = "/tmp/swabby-extract.lock"

TRANSCRIPT_PROMPT = """You are a memory extraction system. Analyze this conversation transcript and extract structured memories.

For each memory, output a JSON object on its own line:
- "type": one of "fact", "decision", "preference", "task", "risk", "plan", "lesson"
- "salience": 0.1 (trivia) to 1.0 (critical)
- "scene": short topic label (e.g. "infrastructure", "k8s", "workflow", "personal")
- "content": concise 1-2 sentence statement, self-contained

Rules:
- Extract 3-15 memories. Quality over quantity.
- Focus on: decisions made, facts learned, preferences expressed, lessons, risks
- Skip: routine tool output, heartbeat checks, pleasantries, temporary context
- Use present tense for facts/preferences, past tense for events/decisions

Output ONLY JSON lines, nothing else.

TRANSCRIPT:
"""

MARKDOWN_PROMPT = """You are a memory extraction system. Analyze these session notes and extract structured memories worth keeping long-term.

For each memory, output a JSON object on its own line:
- "type": one of "fact", "decision", "preference", "task", "risk", "plan", "lesson"
- "salience": 0.1 (trivia) to 1.0 (critical)
- "scene": short topic label (e.g. "infrastructure", "k8s", "workflow", "personal")
- "content": concise 1-2 sentence statement, self-contained

Rules:
- Extract 5-15 memories. Quality over quantity.
- Focus on: decisions made, facts learned, preferences expressed, infrastructure changes, lessons
- Skip: routine heartbeat output, resolved/temporary issues, pleasantries
- Each memory must make sense without the source file

Output ONLY JSON lines, nothing else.

NOTES:
"""

# Scene label → file mapping
SCENE_FILE_MAP = {
    "infra": "scene-infrastructure.md", "infrastructure": "scene-infrastructure.md",
    "k8s": "scene-infrastructure.md", "kubernetes": "scene-infrastructure.md",
    "networking": "scene-infrastructure.md", "network": "scene-infrastructure.md",
    "config": "scene-config.md", "gateway": "scene-config.md",
    "openclaw": "scene-config.md", "configuration": "scene-config.md",
    "projects": "scene-projects.md", "project": "scene-projects.md",
    "cyrano": "scene-projects.md", "groomer": "scene-projects.md",
    "archy": "scene-projects.md", "foreman": "scene-projects.md",
    "lessons": "scene-lessons.md", "lesson": "scene-lessons.md",
    "commodore": "scene-commodore.md", "personal": "scene-commodore.md",
    "preferences": "scene-commodore.md",
    "accounts": "scene-accounts.md", "account": "scene-accounts.md",
    "auth": "scene-accounts.md",
}
SCENE_FILE_DEFAULT = "scene-infrastructure.md"


# ── Transcript helpers ────────────────────────────────────────────────────────

def extract_archived_content(pre_trim_file, trimmed_file):
    """Return messages that were archived (present in pre-trim, absent from trimmed)."""
    pre_entries = []
    with open(pre_trim_file) as f:
        for line in f:
            line = line.strip()
            if line:
                try: pre_entries.append(json.loads(line))
                except: pass

    kept_ids = set()
    if trimmed_file != pre_trim_file:
        with open(trimmed_file) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        e = json.loads(line)
                        if e.get("id"): kept_ids.add(e["id"])
                    except: pass

    messages = []
    for e in pre_entries:
        if e.get("type") != "message": continue
        if e.get("id") in kept_ids: continue
        role = e.get("message", {}).get("role", "")
        if role not in ("user", "assistant"): continue
        content = _extract_text(e.get("message", {}).get("content", ""))
        if content:
            messages.append({"role": role, "content": content})
    return messages


def extract_full_transcript_content(jsonl_file):
    """Read all meaningful user/assistant messages from a JSONL transcript."""
    messages = []
    with open(jsonl_file) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                e = json.loads(line)
                if e.get("type") != "message": continue
                role = e.get("message", {}).get("role", "")
                if role not in ("user", "assistant"): continue
                content = _extract_text(e.get("message", {}).get("content", ""))
                if content:
                    messages.append({"role": role, "content": content})
            except: pass
    return messages


def _extract_text(content):
    if isinstance(content, list):
        parts = [c.get("text", "") for c in content if c.get("type") == "text"]
        content = " ".join(parts)
    content = content.strip() if isinstance(content, str) else ""
    skip = {"NO_REPLY", "HEARTBEAT_OK", "ANNOUNCE_SKIP", "REPLY_SKIP"}
    if content in skip or content.startswith("Read HEARTBEAT"): return ""
    return content


def format_transcript(messages, max_chars):
    lines = [f"[{'User' if m['role'] == 'user' else 'Assistant'}]: {m['content']}\n"
             for m in messages]
    text = "".join(lines)
    if len(text) > max_chars:
        head = int(max_chars * 0.3)
        tail = max_chars - head - 50
        text = text[:head] + "\n[... middle truncated ...]\n" + text[-tail:]
    return text


# ── LLM + parsing ────────────────────────────────────────────────────────────

def call_llm(api_url, api_token, prompt_text, model, timeout_secs):
    import urllib.request
    payload = json.dumps({
        "model": model, "max_tokens": 2000, "temperature": 0.3,
        "messages": [{"role": "user", "content": prompt_text}],
    }).encode()
    req = urllib.request.Request(
        f"{api_url}/v1/chat/completions",
        data=payload,
        headers={"Authorization": f"Bearer {api_token}", "Content-Type": "application/json"},
    )
    def _timeout(s, f): raise TimeoutError(f"LLM call timed out after {timeout_secs}s")
    signal.signal(signal.SIGALRM, _timeout)
    signal.alarm(timeout_secs)
    try:
        with urllib.request.urlopen(req, timeout=timeout_secs) as r:
            result = json.loads(r.read())
        signal.alarm(0)
        return result["choices"][0]["message"]["content"]
    except Exception as e:
        signal.alarm(0)
        raise RuntimeError(f"LLM API error: {e}")


def parse_memories(llm_output, max_memories):
    memories = []
    for line in llm_output.strip().split("\n"):
        line = line.strip()
        if not line or not line.startswith("{"): continue
        try:
            m = json.loads(line)
            if not all(k in m for k in ("type", "salience", "scene", "content")): continue
            if m["type"] not in ("fact", "decision", "preference", "task", "risk", "plan", "lesson"): continue
            if not (0.0 <= float(m["salience"]) <= 1.0): continue
            if not (5 <= len(m["content"]) <= 500): continue
            memories.append(m)
        except: pass
    return memories[:max_memories]


# ── Storage ───────────────────────────────────────────────────────────────────

def store_memories(memories, mem_enabled, mem_path, scene_dir):
    stored = 0
    if mem_enabled:
        for m in memories:
            try:
                r = subprocess.run(
                    [mem_path, "quick-store", m["scene"], m["type"], str(m["salience"]), m["content"]],
                    capture_output=True, text=True, timeout=15,
                )
                if r.returncode == 0:
                    stored += 1
                else:
                    print(f"mem store failed: {r.stderr.strip() or r.stdout.strip()}", file=sys.stderr)
            except Exception as e:
                print(f"mem store error: {e}", file=sys.stderr)

    if scene_dir and os.path.isdir(scene_dir):
        written = _write_scene_files(memories, scene_dir)
        if written:
            _git_commit(scene_dir)
            print(f"Wrote {written} memories to scene files")

    return stored


def _write_scene_files(memories, scene_dir):
    today = date.today().isoformat()
    written = 0
    for m in memories:
        fname = SCENE_FILE_MAP.get(m.get("scene", "").lower(), SCENE_FILE_DEFAULT)
        fpath = os.path.join(scene_dir, fname)
        line = f"- [{m['type']}] (sal: {float(m['salience']):.1f}) {m['content'].replace(chr(10), ' ').strip()}  # extract {today}\n"
        try:
            with open(fpath, "a") as f:
                f.write(line)
            written += 1
        except Exception as e:
            print(f"scene file write error: {e}", file=sys.stderr)
    return written


def _git_commit(scene_dir):
    repo_dir = os.path.dirname(os.path.dirname(scene_dir))
    try:
        scene_files = glob.glob(os.path.join(scene_dir, "scene-*.md"))
        changed = []
        for sf in scene_files:
            rel = os.path.relpath(sf, repo_dir)
            r = subprocess.run(["git", "-C", repo_dir, "diff", "--quiet", rel],
                               capture_output=True, timeout=5)
            if r.returncode != 0:
                changed.append(rel)
        if not changed: return
        for rel in changed:
            subprocess.run(["git", "-C", repo_dir, "add", rel], timeout=5, check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-m",
                        f"extract: scene file update {date.today().isoformat()}"],
                       timeout=10, check=True)
        subprocess.run(["git", "-C", repo_dir, "push"], timeout=30, check=True)
        print(f"Committed and pushed {len(changed)} scene file(s)")
    except Exception as e:
        print(f"git commit non-fatal: {e}", file=sys.stderr)


# ── State / dedup ─────────────────────────────────────────────────────────────

def load_state(state_file):
    if os.path.exists(state_file):
        try: return json.load(open(state_file))
        except: pass
    return {}


def save_state(state_file, state, dedup_key, memories, stored, input_chars):
    extracted = state.get("llm_extracted", {})
    extracted[dedup_key] = {
        "timestamp": datetime.now().isoformat(),
        "memories": len(memories), "stored": stored, "input_chars": input_chars,
    }
    # Trim to 200 entries (keep most recent)
    if len(extracted) > 200:
        for k in sorted(extracted, key=lambda k: extracted[k].get("timestamp", ""))[:100]:
            del extracted[k]
    state["llm_extracted"] = extracted
    state["lastLlmRun"] = datetime.now().isoformat()
    json.dump(state, open(state_file, "w"), indent=2)


# ── Entry points ──────────────────────────────────────────────────────────────

def run_transcript(args):
    pre_trim = args.file
    trimmed = args.trimmed or args.file  # default: same file → full content mode
    sid = args.sid or os.path.basename(pre_trim)
    dedup_key = f"transcript-{sid}-{os.path.basename(pre_trim)}"

    state = load_state(args.state)
    if dedup_key in state.get("llm_extracted", {}):
        print(f"Already extracted {dedup_key} — skipping")
        sys.exit(1)

    if not os.path.exists(pre_trim):
        print(f"File not found: {pre_trim}", file=sys.stderr)
        sys.exit(1)

    messages = extract_archived_content(pre_trim, trimmed)
    fallback = False
    if len(messages) < args.min_archived:
        print(f"Only {len(messages)} archived messages — falling back to full content")
        messages = extract_full_transcript_content(pre_trim)
        fallback = True
        if len(messages) < args.min_archived:
            print(f"Only {len(messages)} messages total — insufficient, skipping")
            state.setdefault("skipped", {})[f"skip-{dedup_key}"] = datetime.now().isoformat()
            json.dump(state, open(args.state, "w"), indent=2)
            sys.exit(1)

    text = format_transcript(messages, args.max_chars)
    mode = "full fallback" if fallback else "archived diff"
    print(f"Sending {len(text)} chars ({len(messages)} messages, {mode}) to LLM...")

    try:
        llm_out = call_llm(args.api_url, args.api_token, TRANSCRIPT_PROMPT + text,
                           args.model, args.timeout)
    except Exception as e:
        print(f"LLM failed: {e}", file=sys.stderr)
        sys.exit(2)

    memories = parse_memories(llm_out, args.max_memories)
    if not memories:
        print("No valid memories extracted")
        sys.exit(1)

    stored = store_memories(memories, args.mem_enabled, args.mem_path, args.scene_dir)
    print(f"Extracted {len(memories)} memories, stored {stored} to mem DB")
    save_state(args.state, state, dedup_key, memories, stored, len(text))


def run_markdown(args):
    md_file = args.file
    dedup_key = f"md-{os.path.basename(md_file)}"

    state = load_state(args.state)
    if dedup_key in state.get("llm_extracted", {}):
        print(f"Already extracted {dedup_key} — skipping")
        sys.exit(1)

    if not os.path.exists(md_file):
        print(f"File not found: {md_file}", file=sys.stderr)
        sys.exit(1)

    with open(md_file) as f:
        content = f.read()

    if len(content) < 200:
        print(f"File too short ({len(content)} chars) — skipping")
        sys.exit(1)

    content = content[:args.max_chars]
    print(f"Extracting from {os.path.basename(md_file)} ({len(content)} chars)...")

    try:
        llm_out = call_llm(args.api_url, args.api_token, MARKDOWN_PROMPT + content,
                           args.model, args.timeout)
    except Exception as e:
        print(f"LLM failed: {e}", file=sys.stderr)
        sys.exit(2)

    memories = parse_memories(llm_out, args.max_memories)
    if not memories:
        print("No valid memories extracted")
        sys.exit(1)

    stored = store_memories(memories, args.mem_enabled, args.mem_path, args.scene_dir)
    print(f"Extracted {len(memories)}, stored {stored} to mem DB")
    save_state(args.state, state, dedup_key, memories, stored, len(content))


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Unified memory extractor")
    sub = parser.add_subparsers(dest="mode", required=True)

    # Shared args factory
    def add_common(p):
        p.add_argument("file", help="Input file")
        p.add_argument("--state", default="/home/swabby/.openclaw/session-janitor-state.json")
        p.add_argument("--api-url", default="http://127.0.0.1:18789")
        p.add_argument("--api-token", default="aee524da0214f9a1616e00c1d769eba03721c9c7e79133cd")
        p.add_argument("--mem-enabled", action="store_true")
        p.add_argument("--mem-path", default="/home/swabby/bin/mem")
        p.add_argument("--scene-dir", default=None)
        p.add_argument("--model", default="openclaw")
        p.add_argument("--max-chars", type=int, default=20000)
        p.add_argument("--timeout", type=int, default=90)
        p.add_argument("--max-memories", type=int, default=15)

    # transcript subcommand
    tp = sub.add_parser("transcript", help="Extract from JSONL session transcript")
    add_common(tp)
    tp.add_argument("--trimmed", default=None, help="Trimmed version (omit for full-file mode)")
    tp.add_argument("--sid", default=None, help="Session ID for dedup key")
    tp.add_argument("--min-archived", type=int, default=3)

    # markdown subcommand
    mp = sub.add_parser("markdown", help="Extract from plain markdown notes file")
    add_common(mp)

    args = parser.parse_args()

    # Lockfile (shared across both modes — only one extraction at a time)
    lock_fd = None
    try:
        lock_fd = open(LOCKFILE, "w")
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (IOError, OSError):
        print("Another extraction is running — skipping")
        sys.exit(1)

    try:
        if args.mode == "transcript":
            run_transcript(args)
        else:
            run_markdown(args)
    finally:
        if lock_fd:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            lock_fd.close()
            try: os.unlink(LOCKFILE)
            except: pass


if __name__ == "__main__":
    main()
