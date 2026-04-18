#!/usr/bin/env bash
# delegation-enforcer.sh — PreToolUse hook for claude-dual
#
# Counts direct Read/Edit/Write/Grep/Glob calls Opus makes per session and prints
# escalating reminders to delegate to GLM subagents. Non-blocking (always exits 0).
#
# Fires at 3, 7, and 15 calls per session. State in /tmp/claude-dual-delegation/.

set -euo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | grep -o '"tool_name":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
SESSION=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
SESSION="${SESSION:-default}"

case "$TOOL" in
  Read|Edit|Write|Grep|Glob) ;;
  *) exit 0 ;;
esac

STATE_DIR="/tmp/claude-dual-delegation"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
COUNT_FILE="$STATE_DIR/$SESSION.count"
WARNED_FILE="$STATE_DIR/$SESSION.warned"

COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNT_FILE"

WARNED=$(cat "$WARNED_FILE" 2>/dev/null || echo 0)

for THRESHOLD in 3 7 15; do
  if [ "$COUNT" -eq "$THRESHOLD" ] && [ "$WARNED" -lt "$THRESHOLD" ]; then
    cat >&2 <<EOF
[delegation-enforcer] This session has made $COUNT direct Read/Edit/Write/Grep/Glob calls.

Per ~/.claude/CLAUDE.md: investigation tasks (reading >2 files, broad greps) should
dispatch glm-explorer. Bulk edits (>1 file, >20 lines, refactors) should dispatch
glm-worker. Diff reviews should dispatch glm-reviewer. GLM thinking is free (32k
budget) and parallelizable — coordination overhead is NOT a valid reason to skip
delegation.

Non-blocking reminder. Proceed if remaining work is a single targeted operation;
otherwise batch-delegate what's left.
EOF
    echo "$THRESHOLD" > "$WARNED_FILE"
  fi
done

exit 0
