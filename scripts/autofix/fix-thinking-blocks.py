#!/usr/bin/env python3
"""
fix-thinking-blocks.py — Remove malformed thinking blocks from gateway JSONL transcripts.

A thinking block is malformed if its `thinking` field is:
  - a dict (was parsed instead of left as raw string)
  - None / null
  - an empty string
  - a non-string scalar

Reads gateway dirs from the session-janitor config.json.
Writes back fixed JSONL atomically (temp + rename).

Exit codes:
  0 — success (even if nothing needed fixing)
  1 — fatal error (config not found, unreadable, etc.)
"""

import json
import os
import shutil
import sys
import tempfile
from pathlib import Path


def find_config() -> Path:
    """Locate config.json relative to this script's location."""
    script_dir = Path(__file__).resolve().parent
    # scripts/autofix/ -> scripts/ -> skill root
    candidates = [
        script_dir.parent.parent / "config.json",
        Path(__file__).resolve().parent.parent.parent / "config.json",
    ]
    for c in candidates:
        if c.exists():
            return c
    raise FileNotFoundError(f"config.json not found; tried: {candidates}")


def is_malformed_thinking(block: dict) -> bool:
    """Return True if the thinking block's `thinking` field is malformed."""
    thinking = block.get("thinking")
    if thinking is None:
        return True
    if isinstance(thinking, dict):
        return True
    if isinstance(thinking, str) and not thinking.strip():
        return True
    # Any other non-string type (int, list, bool, …)
    if not isinstance(thinking, str):
        return True
    return False


def fix_jsonl_file(path: Path) -> tuple[int, bool]:
    """
    Scan one JSONL file for malformed thinking blocks and remove them.

    Returns (blocks_removed, file_was_written).
    """
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    blocks_removed = 0
    new_lines = []
    changed = False

    for lineno, line in enumerate(lines, 1):
        raw = line.rstrip("\n")
        if not raw.strip():
            new_lines.append(line)
            continue

        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            # Non-parseable line — leave it alone
            new_lines.append(line)
            continue

        if entry.get("type") != "message":
            new_lines.append(line)
            continue

        message = entry.get("message")
        if not isinstance(message, dict):
            new_lines.append(line)
            continue

        content = message.get("content")
        if not isinstance(content, list):
            new_lines.append(line)
            continue

        # Filter out malformed thinking blocks
        filtered = []
        for block in content:
            if (
                isinstance(block, dict)
                and block.get("type") == "thinking"
                and is_malformed_thinking(block)
            ):
                blocks_removed += 1
                changed = True
                print(
                    f"  [{path.name}:{lineno}] removed malformed thinking block "
                    f"(thinking={type(block.get('thinking')).__name__!r})",
                    flush=True,
                )
            else:
                filtered.append(block)

        if changed and len(filtered) != len(content):
            message["content"] = filtered
            entry["message"] = message
            new_lines.append(json.dumps(entry, ensure_ascii=False) + "\n")
        else:
            new_lines.append(line)

    if changed:
        # Atomic write: temp file in same dir, then rename
        tmp_fd, tmp_path = tempfile.mkstemp(
            dir=path.parent, prefix=".fix-thinking-", suffix=".tmp"
        )
        try:
            with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
                f.writelines(new_lines)
            shutil.move(tmp_path, path)
        except Exception:
            os.unlink(tmp_path)
            raise

    return blocks_removed, changed


def main() -> int:
    try:
        config_path = find_config()
    except FileNotFoundError as e:
        print(f"FATAL: {e}", file=sys.stderr)
        return 1

    try:
        config = json.loads(config_path.read_text())
    except Exception as e:
        print(f"FATAL: cannot parse config: {e}", file=sys.stderr)
        return 1

    gateways = config.get("gateways", [])
    if not gateways:
        print("FATAL: no gateways configured", file=sys.stderr)
        return 1

    files_scanned = 0
    files_fixed = 0
    total_blocks_removed = 0

    for gw in gateways:
        gw_name = gw.get("name", "?")
        sessions_dir = gw.get("sessionsDir", "")
        if not sessions_dir:
            print(f"  [{gw_name}] no sessionsDir — skipping", flush=True)
            continue

        sessions_path = Path(sessions_dir).expanduser()
        if not sessions_path.is_dir():
            print(f"  [{gw_name}] sessionsDir not found: {sessions_path} — skipping", flush=True)
            continue

        # Scan all JSONL files (excluding archives)
        skip_suffixes = (".reset.", ".deleted.", ".pre-trim.", ".trajectory.", ".tmp")
        for jsonl_path in sorted(sessions_path.glob("*.jsonl")):
            name = jsonl_path.name
            if any(s in name for s in skip_suffixes):
                continue

            files_scanned += 1
            try:
                removed, fixed = fix_jsonl_file(jsonl_path)
            except Exception as e:
                print(f"  [{gw_name}] ERROR processing {name}: {e}", file=sys.stderr)
                continue

            if fixed:
                files_fixed += 1
                total_blocks_removed += removed
                print(f"  [{gw_name}] fixed {name}: removed {removed} block(s)", flush=True)

    print(
        f"\nSummary: scanned {files_scanned} file(s), "
        f"fixed {files_fixed} file(s), "
        f"removed {total_blocks_removed} malformed thinking block(s).",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
