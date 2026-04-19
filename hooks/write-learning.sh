#!/bin/bash
# write-learning: append a one-line postmortem to the learnings fabric.
# Called by subagents at task exit via Bash tool:
#   ~/.claude-dual/write-learning.sh <agent> <task_type> <outcome> <what_worked> [what_failed] [tags,csv]
#
# Every field is a single string. JSON escaping handled internally.
# Entries are append-only; corruption isolated to the bad line.

set -eu

LEARNINGS_FILE="${HOME}/.claude-dual/memory/learnings.jsonl"
MAX_BYTES=$((10 * 1024 * 1024))  # 10MB soft cap; rotate if exceeded

agent="${1:?agent name required}"
task_type="${2:?task type required}"
outcome="${3:?outcome required (success|failure|partial)}"
what_worked="${4:-}"
what_failed="${5:-}"
tags="${6:-}"

# Rotate if too big
if [ -f "$LEARNINGS_FILE" ]; then
  size=$(wc -c < "$LEARNINGS_FILE" | tr -d ' ')
  if [ "$size" -gt "$MAX_BYTES" ]; then
    mv "$LEARNINGS_FILE" "${LEARNINGS_FILE%.jsonl}.$(date -u +%Y%m%d).jsonl"
    touch "$LEARNINGS_FILE"
  fi
fi

# Build JSON via python3 for robust escaping
python3 - "$agent" "$task_type" "$outcome" "$what_worked" "$what_failed" "$tags" <<'PY' >> "$LEARNINGS_FILE"
import json, sys, datetime
agent, task_type, outcome, ww, wf, tags = sys.argv[1:7]
rec = {
  "ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
  "agent": agent,
  "task_type": task_type,
  "approach": "",
  "outcome": outcome,
  "what_worked": ww[:500],
  "what_failed": wf[:500],
  "verified": False,
  "tags": [t.strip() for t in tags.split(",") if t.strip()],
}
print(json.dumps(rec, ensure_ascii=False))
PY

echo "learning recorded: $agent/$task_type/$outcome" >&2
