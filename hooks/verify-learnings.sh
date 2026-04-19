#!/bin/bash
# verify-learnings: PostToolUse hook on Bash. When the command that just ran
# looks like a test / lint / type-check AND exited 0, flip verified:true on
# the most recent UNVERIFIED learnings (last 5 minutes, written by glm-*
# agents). Turns the fabric from "GLM says it worked" into "tests say it
# worked" — gives fetch-learnings' verified-bonus real signal.
#
# PostToolUse payload contains tool_input + tool_response. We only care
# about Bash calls, and only when the command matches a test-runner
# pattern and the response indicates success.

set -eu

LEARNINGS_FILE="${HOME}/.claude-dual/memory/learnings.jsonl"
[ -f "$LEARNINGS_FILE" ] || exit 0

payload=$(cat)
export HOOK_PAYLOAD="$payload"
export LEARNINGS_PATH="$LEARNINGS_FILE"

python3 <<'PY'
import json, os, re, sys, datetime, tempfile, shutil

payload_raw = os.environ.get("HOOK_PAYLOAD", "")
path = os.environ["LEARNINGS_PATH"]

try:
    data = json.loads(payload_raw)
except Exception:
    sys.exit(0)

tool_name = data.get("tool_name", "")
if tool_name != "Bash":
    sys.exit(0)

tool_input = data.get("tool_input", {}) or {}
tool_response = data.get("tool_response", {}) or {}

cmd = (tool_input.get("command") or "").lower()
if not cmd:
    sys.exit(0)

# Test / lint / type-check patterns. Broad enough to catch real runs,
# tight enough to skip incidentals (ls, cat, echo, git status).
TEST_PATTERNS = [
    r'\bpytest\b', r'\bpython\s+-m\s+pytest\b',
    r'\bnpm\s+(run\s+)?test\b', r'\bnpm\s+(run\s+)?lint\b',
    r'\bnpx\s+(jest|vitest|mocha|tsc|eslint|playwright)\b',
    r'\byarn\s+(test|lint)\b', r'\bpnpm\s+(test|lint)\b',
    r'\bjest\b', r'\bvitest\b', r'\bmocha\b',
    r'\bcargo\s+(test|check|clippy)\b',
    r'\bgo\s+test\b', r'\bgo\s+vet\b',
    r'\bruff\b', r'\bmypy\b', r'\bpyright\b', r'\bblack\s+--check\b',
    r'\btsc(\s|$)', r'\beslint\b', r'\bprettier\s+--check\b',
    r'\brspec\b', r'\brake\s+test\b',
    r'\bphpunit\b', r'\bphpstan\b',
    r'\bmake\s+(test|check|lint)\b',
    r'\bbun\s+test\b',
]
if not any(re.search(p, cmd) for p in TEST_PATTERNS):
    sys.exit(0)

# Determine success: PostToolUse payload shape varies by CC version.
# Try common shapes: tool_response.stderr == "" && no error flag, or
# interrupted == false, or stdout present without "FAIL"/"error" tokens.
is_error = tool_response.get("is_error") or tool_response.get("interrupted")
if is_error:
    sys.exit(0)

stderr = (tool_response.get("stderr") or "").lower()
stdout = (tool_response.get("stdout") or tool_response.get("output") or "").lower()
combined = stdout + "\n" + stderr

# Heuristic failure markers. Be conservative — only skip verify on CLEAR failure.
FAIL_MARKERS = [
    r'\bfailed\b', r'\bfailure\b', r'\bfailures\b',
    r'\berror:', r'\berrors\b.*\bfound\b',
    r'\btraceback\b', r'assertionerror',
    r'\b[1-9]\d* (failed|errors?|problems?)\b',
    r'exit(ing)? (with )?(code|status) [1-9]',
    r'✗', r'❌',
    r'not ok \d+',
    r'process exited with code [1-9]',
]
if any(re.search(p, combined) for p in FAIL_MARKERS):
    # Also check for the "0 failed" case which contains "failed" but is success
    if re.search(r'\b0 (failed|errors?|failures?)\b', combined):
        pass  # success
    else:
        sys.exit(0)

# We have a passing test run. Flip verified:true on recent unverified
# learnings written by glm-* agents in the last 5 minutes.
now = datetime.datetime.utcnow()
WINDOW_SECONDS = 300

try:
    with open(path, "r") as f:
        lines = f.readlines()
except Exception:
    sys.exit(0)

if not lines:
    sys.exit(0)

flipped = 0
new_lines = []
for line in lines:
    s = line.strip()
    if not s:
        new_lines.append(line)
        continue
    try:
        rec = json.loads(s)
    except Exception:
        new_lines.append(line)
        continue
    if rec.get("verified"):
        new_lines.append(line)
        continue
    agent = rec.get("agent", "")
    if not agent.startswith("glm-"):
        new_lines.append(line)
        continue
    try:
        ts = datetime.datetime.strptime(rec["ts"], "%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        new_lines.append(line)
        continue
    if (now - ts).total_seconds() > WINDOW_SECONDS:
        new_lines.append(line)
        continue
    # In-window, glm-agent, unverified, test passed → flip.
    rec["verified"] = True
    rec["verified_by"] = "test_pass"
    rec["verified_cmd"] = cmd[:200]
    new_lines.append(json.dumps(rec, ensure_ascii=False) + "\n")
    flipped += 1

if flipped == 0:
    sys.exit(0)

# Atomic write via tempfile + rename
tmp_fd, tmp_path = tempfile.mkstemp(
    prefix=".learnings.", dir=os.path.dirname(path)
)
try:
    with os.fdopen(tmp_fd, "w") as tf:
        tf.writelines(new_lines)
    shutil.move(tmp_path, path)
except Exception:
    try:
        os.unlink(tmp_path)
    except Exception:
        pass
    sys.exit(0)

# Silent on success — PostToolUse doesn't need to yell at Opus every test run.
# Log to stderr for debugging.
sys.stderr.write(f"verify-learnings: flipped {flipped} entries to verified=true\n")
PY
