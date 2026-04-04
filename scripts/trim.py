#!/usr/bin/env python3
"""Trim an oversized JSONL transcript: keep session header + synthetic compaction + recent exchanges.

Usage: trim.py <jsonl_file> <session_id> <gateway_name> <state_file> [keep_pairs]

- Writes a trimmed transcript in-place with:
  - Original session header
  - A synthetic compaction entry summarizing what was archived
  - The last `keep_pairs` user/assistant exchange pairs (default 10)
- Archives the original as .pre-trim.<timestamp>

Exits 0 on success, 1 if nothing to do.
"""
import json, sys, os, shutil, hashlib
from datetime import datetime

def random_id():
    return hashlib.md5(os.urandom(8)).hexdigest()[:8]

def main():
    jsonl_file = sys.argv[1]
    session_id = sys.argv[2]
    gateway = sys.argv[3]
    state_file = sys.argv[4]
    keep_pairs = int(sys.argv[5]) if len(sys.argv) > 5 else 10

    entries = []
    with open(jsonl_file) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: entries.append(json.loads(line))
            except: continue

    if not entries: sys.exit(1)

    header = None
    content_entries = []
    for e in entries:
        if e.get("type") == "session":
            header = e
        else:
            content_entries.append(e)

    if not header:
        print(f"No session header in {jsonl_file}", file=sys.stderr)
        sys.exit(1)

    message_entries = []
    other_entries = []
    for e in content_entries:
        if e.get("type") == "message":
            role = e.get("message", {}).get("role", "")
            if role in ("user", "assistant"):
                message_entries.append(e)
            else:
                other_entries.append(e)
        else:
            other_entries.append(e)

    total_user = sum(1 for e in message_entries if e.get("message", {}).get("role") == "user")
    if total_user < keep_pairs:
        print(f"Only {total_user} user messages (need {keep_pairs}) — skipping")
        sys.exit(1)

    user_count = 0
    cut_index = len(message_entries)
    for i in range(len(message_entries) - 1, -1, -1):
        if message_entries[i].get("message", {}).get("role") == "user":
            user_count += 1
            if user_count >= keep_pairs:
                cut_index = i
                break

    kept_messages = message_entries[cut_index:]
    archived_messages = message_entries[:cut_index]

    if len(kept_messages) == 0:
        print(f"Would keep 0 messages — aborting trim")
        sys.exit(1)

    if len(archived_messages) < 5:
        print(f"Only {len(archived_messages)} old messages — not worth trimming")
        sys.exit(1)

    # Build topic summary for compaction entry
    user_topics = []
    for e in archived_messages:
        if e.get("message", {}).get("role") != "user": continue
        content = e.get("message", {}).get("content", "")
        if isinstance(content, list):
            content = " ".join(c.get("text", "") for c in content if c.get("type") == "text")
        content = content.strip()
        if content and len(content) > 5:
            if len(content) > 200: content = content[:200] + "..."
            user_topics.append(content)

    # Build trimmed transcript
    trimmed = [header]

    summary_lines = [
        "## Archived Context", "",
        f"{len(archived_messages)} older messages were archived to memory files by transcript maintenance.",
        f"Key topics: {'; '.join(t[:80] for t in user_topics[:5])}{'...' if len(user_topics) > 5 else ''}",
        "", "Recent conversation continues below.",
    ]

    first_kept_id = kept_messages[0].get("id") if kept_messages else None
    last_parent = header.get("id", random_id())

    compaction_entry = {
        "type": "compaction",
        "id": random_id(),
        "parentId": last_parent,
        "timestamp": datetime.now(tz=__import__('datetime').timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "summary": "\n".join(summary_lines),
        "firstKeptEntryId": first_kept_id,
        "tokensBefore": 0,
    }
    trimmed.append(compaction_entry)

    prev_id = compaction_entry["id"]
    for e in kept_messages:
        e["parentId"] = prev_id
        if "id" not in e: e["id"] = random_id()
        prev_id = e["id"]
        trimmed.append(e)

    kept_ids = {e.get("id") for e in kept_messages}
    for e in other_entries:
        if e.get("parentId") and e["parentId"] in kept_ids:
            trimmed.append(e)

    # Archive original, write trimmed
    archive_path = f"{jsonl_file}.pre-trim.{datetime.now(tz=__import__('datetime').timezone.utc).strftime('%Y-%m-%dT%H-%M-%SZ')}"
    shutil.move(jsonl_file, archive_path)

    with open(jsonl_file, "w") as f:
        for entry in trimmed:
            f.write(json.dumps(entry) + "\n")

    orig_kb = os.path.getsize(archive_path) // 1024
    new_kb = os.path.getsize(jsonl_file) // 1024
    print(f"Trimmed {session_id[:12]}: {orig_kb}KB → {new_kb}KB "
          f"({len(archived_messages)} archived, {len(kept_messages)} kept)")

if __name__ == "__main__":
    main()
