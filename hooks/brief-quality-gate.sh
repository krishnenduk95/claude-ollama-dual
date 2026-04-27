#!/usr/bin/env bash
# brief-quality-gate.sh — PreToolUse hook for claude-dual
#
# Warns when an Agent/Task dispatch brief is missing key fields (Goal,
# Acceptance criteria, File list). The warning is informational — does NOT block.
#
# Fires on PreToolUse for Agent and Task tools.
# Protocol: hookSpecificOutput.additionalContext (JSON to stdout).
# Exit 0 always. Never block.

set -eu

payload=$(cat)
export HOOK_PAYLOAD="$payload"

python3 <<'PY'
import json, os, re, sys

try:
    payload = json.loads(os.environ.get("HOOK_PAYLOAD", ""))
except json.JSONDecodeError:
    sys.exit(0)

tool_name = payload.get("tool_name", "")
if tool_name not in ("Agent", "Task"):
    sys.exit(0)

tool_input = payload.get("tool_input", {}) or {}
prompt = str(tool_input.get("prompt", "") or "")
if not prompt.strip():
    sys.exit(0)

missing = []

# Goal: contains "goal:" (case-insensitive) anywhere, or line starting with "goal "
# (case-insensitive, multiline).  Covers: "GOAL:", "Goal:", "goal:", "Goal ", "goal ", "GOAL "
if not re.search(r"^goal[:\s]|goal:", prompt, re.IGNORECASE | re.MULTILINE):
    missing.append("Goal")

# Acceptance criteria: contains "acceptance" (word), "must pass", "verify", or "expected:"
if not re.search(r"\bacceptance\b|must pass|verify|expected[:\s]", prompt, re.IGNORECASE):
    missing.append("Acceptance criteria")

# File list: at least one path-shaped token: absolute (/path), home-relative (~/path), or relative (dir/file)
if not re.search(r"/\S+|~\S+|\b\w+/\S+", prompt):
    missing.append("File list")

if not missing:
    sys.exit(0)

msg = (
    "\U0001f4cb BRIEF QUALITY GATE: this dispatch is missing: [%s]. "
    "Vague briefs produce sloppy output — consider adding before sending."
) % ", ".join(missing)

out = {
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "additionalContext": msg
    }
}
print(json.dumps(out))
PY
exit 0
