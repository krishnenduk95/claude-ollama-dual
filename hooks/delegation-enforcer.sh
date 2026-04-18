#!/usr/bin/env bash
# delegation-enforcer.sh — PreToolUse hook for claude-dual
#
# Counts direct Read/Edit/Write/Grep/Glob calls Opus makes per session and
# feeds escalating reminders back into the conversation using Claude Code's
# hookSpecificOutput.additionalContext JSON protocol (visible to the model).
#
# Thresholds:
#   3  → additionalContext nudge (visible to Opus, non-blocking)
#   7  → stronger additionalContext warning (visible, non-blocking)
#   15 → BLOCK (exit 2 + stderr) — session has gone off the rails; must pivot to GLM
#
# State in /tmp/claude-dual-delegation/.

set -uo pipefail

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

emit_context() {
  local msg="$1"
  # Escape for JSON: replace newlines with \n, escape quotes
  local escaped
  escaped=$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null)
  if [ -z "$escaped" ]; then
    # Fallback: use sed if python missing
    escaped=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')
    escaped="\"$escaped\""
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":%s}}\n' "$escaped"
}

# Threshold 3 — gentle nudge (visible in Opus context)
if [ "$COUNT" -eq 3 ] && [ "$WARNED" -lt 3 ]; then
  echo 3 > "$WARNED_FILE"
  emit_context "[delegation-enforcer] You have made 3 direct Read/Edit/Write/Grep/Glob calls this session. Per ~/.claude/CLAUDE.md delegation rules: if you have MORE similar work to do (reading more files, searching broadly, or editing), STOP and dispatch glm-explorer (investigation) or glm-worker (bulk edits) instead of continuing yourself. GLM thinking is free and parallelizable. If your remaining work is a single targeted operation (one known file, <20 lines, needs staff judgment), proceed."
  exit 0
fi

# Threshold 7 — stronger warning (visible in Opus context)
if [ "$COUNT" -eq 7 ] && [ "$WARNED" -lt 7 ]; then
  echo 7 > "$WARNED_FILE"
  emit_context "[delegation-enforcer] You are at 7 direct tool calls this session — this is the pattern of NOT delegating. Per claude-dual rules, by now you should have batched remaining investigation into a glm-explorer brief or bulk edits into a glm-worker brief. Before your NEXT Read/Edit/Write/Grep/Glob, ask yourself: can the remaining work be expressed as a single GLM brief with file paths and acceptance criteria? If yes, dispatch GLM NOW instead of continuing manually."
  exit 0
fi

# Threshold 15 — BLOCK. 15 direct tool calls in one session means delegation has failed.
if [ "$COUNT" -ge 15 ] && [ "$WARNED" -lt 15 ]; then
  echo 15 > "$WARNED_FILE"
  cat >&2 <<'EOF'
[delegation-enforcer] BLOCKED: 15 direct Read/Edit/Write/Grep/Glob calls in one session.

This violates the claude-dual delegation contract in ~/.claude/CLAUDE.md. Dispatch a GLM subagent for the remaining work:

  - Investigating the codebase? → Agent(subagent_type="glm-explorer", prompt="...")
  - Bulk edits or new files? → Agent(subagent_type="glm-worker", prompt="...")
  - Reviewing a diff? → Agent(subagent_type="glm-reviewer", prompt="...")
  - Analyzing tradeoffs? → Agent(subagent_type="glm-analyst", prompt="...")

Your GLM brief must include: goal, exact file list, context to read, acceptance criteria, constraints, verification command.

If the current tool call is genuinely a targeted single-file operation requiring staff-level judgment (auth/crypto/billing/migration/concurrency on a KNOWN file with a KNOWN change <20 lines), you may retry by first resetting the counter:
  echo 0 > /tmp/claude-dual-delegation/$SESSION_ID.count

Otherwise: pivot to GLM now.
EOF
  exit 2
fi

exit 0
