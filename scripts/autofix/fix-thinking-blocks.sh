#!/bin/bash
export PATH="/home/swabby/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/fix-thinking-blocks.py" "$@"
