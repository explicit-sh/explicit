#!/usr/bin/env bash
# Claude Code Stop hook — show violations after Claude responds
# Exit 0 = allow stop, exit 2 = block stop (forces Claude to fix violations)

if ! command -v explicit &>/dev/null; then
  exit 0
fi

# Skip if no server running
if ! explicit status --json 2>/dev/null | grep -q '"ok":true'; then
  exit 0
fi

output=$(explicit violations --json 2>/dev/null)
count=$(echo "$output" | grep -o '"total":[0-9]*' | head -1 | cut -d: -f2)

if [ "${count:-0}" -gt 0 ]; then
  echo "$output" >&2
  exit 2
fi

exit 0
