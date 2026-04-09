#!/usr/bin/env python3
"""Sidecar tool-output offloader.

Scans a JSONL transcript for large toolResult entries and moves their content
to sidecar files, replacing the inline content with a compact stub.

Usage:
    sidecar.py <jsonl_file> <session_id> [min_entry_bytes]

Sidecar layout:
    <jsonl_dir>/<session_id>.toolcache/<tool-call-id>.txt

Stub format (replaces inline content):
    [tool output offloaded to .toolcache/<tool-call-id>.txt — <N> bytes.
     Use the Read tool to access it if needed.]

- Idempotent: entries already containing a stub are skipped.
- Atomic write: original is overwritten only if ≥1 entry was changed.
- Restart-safe: sidecar files are adjacent to the transcript, survive gateway
  restarts and config changes.

Exits:
    0 — success (even if nothing was sidecared)
    1 — error
"""
import json
import os
import sys
import shutil
from pathlib import Path
from datetime import datetime, timezone

STUB_MARKER = "[tool output offloaded to"
DEFAULT_MIN_BYTES = 5120  # 5 KB per entry


def entry_content_size(entry: dict) -> int:
    """Return approximate byte size of a toolResult entry's content."""
    raw = entry.get("message", {}).get("content", [])
    if isinstance(raw, str):
        return len(raw.encode("utf-8"))
    total = 0
    for block in raw:
        if isinstance(block, dict) and block.get("type") == "text":
            total += len(block.get("text", "").encode("utf-8"))
    return total


def is_already_stubbed(entry: dict) -> bool:
    raw = entry.get("message", {}).get("content", [])
    if isinstance(raw, str):
        return STUB_MARKER in raw
    for block in raw:
        if isinstance(block, dict) and block.get("type") == "text":
            if STUB_MARKER in block.get("text", ""):
                return True
    return False


def extract_text(entry: dict) -> str:
    """Extract full text content from a toolResult entry."""
    raw = entry.get("message", {}).get("content", [])
    if isinstance(raw, str):
        return raw
    parts = []
    for block in raw:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text", ""))
    return "\n".join(parts)


def make_stub_content(sidecar_filename: str, byte_count: int) -> list:
    return [
        {
            "type": "text",
            "text": (
                f"{STUB_MARKER} .toolcache/{sidecar_filename} — {byte_count} bytes. "
                "Use the Read tool to access it if needed.]"
            ),
        }
    ]


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <jsonl_file> <session_id> [min_entry_bytes]", file=sys.stderr)
        sys.exit(1)

    jsonl_path = Path(sys.argv[1])
    session_id = sys.argv[2]
    min_bytes = int(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_MIN_BYTES

    if not jsonl_path.exists():
        print(f"ERROR: {jsonl_path} not found", file=sys.stderr)
        sys.exit(1)

    # Read transcript
    entries = []
    with open(jsonl_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"WARN: skipping malformed line: {e}", file=sys.stderr)
                continue

    if not entries:
        print("No entries — nothing to do")
        sys.exit(0)

    # Sidecar dir adjacent to the transcript
    toolcache_dir = jsonl_path.parent / f"{session_id}.toolcache"
    sidecared = 0
    changed = []

    for entry in entries:
        msg = entry.get("message", {})
        if msg.get("role") != "toolResult":
            changed.append(entry)
            continue

        if is_already_stubbed(entry):
            changed.append(entry)
            continue

        size = entry_content_size(entry)
        if size < min_bytes:
            changed.append(entry)
            continue

        # Determine sidecar filename
        tcid = msg.get("toolCallId") or msg.get("id") or f"unknown-{sidecared}"
        # Sanitize for filesystem
        safe_id = "".join(c if c.isalnum() or c in "-_." else "_" for c in tcid)
        sidecar_filename = f"{safe_id}.txt"
        sidecar_path = toolcache_dir / sidecar_filename

        # Extract text and write to sidecar
        text = extract_text(entry)
        toolcache_dir.mkdir(parents=True, exist_ok=True)
        sidecar_path.write_text(text, encoding="utf-8")
        actual_bytes = sidecar_path.stat().st_size

        # Replace content with stub
        import copy
        new_entry = copy.deepcopy(entry)
        new_entry["message"]["content"] = make_stub_content(sidecar_filename, actual_bytes)
        new_entry["message"]["_sidecaredBytes"] = actual_bytes
        changed.append(new_entry)
        sidecared += 1

        tool_name = msg.get("toolName", "tool")
        print(
            f"  sidecared {tool_name} ({tcid[:12]}): "
            f"{actual_bytes // 1024}KB → .toolcache/{sidecar_filename}"
        )

    if sidecared == 0:
        print(f"No entries exceeded {min_bytes} bytes — nothing sidecared")
        sys.exit(0)

    # Atomic write
    tmp_path = jsonl_path.with_suffix(".jsonl.sidecar-tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        for entry in changed:
            f.write(json.dumps(entry) + "\n")

    shutil.move(str(tmp_path), str(jsonl_path))

    orig_kb = sum(len(json.dumps(e)) for e in entries) // 1024
    new_kb = jsonl_path.stat().st_size // 1024
    print(
        f"Sidecar complete: {sidecared} entries offloaded, "
        f"{orig_kb}KB → {new_kb}KB "
        f"(sidecar dir: {toolcache_dir})"
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
