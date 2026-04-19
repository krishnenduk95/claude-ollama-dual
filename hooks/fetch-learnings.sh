#!/bin/bash
# fetch-learnings: UserPromptSubmit hook that finds the N most relevant
# past learnings and injects them as additionalContext.
#
# Relevance = keyword overlap between the incoming prompt and each
# learning's task_type + tags + what_worked/what_failed text.
# Time-decay weighting: recent entries score higher.

set -eu

LEARNINGS_FILE="${HOME}/.claude-dual/memory/learnings.jsonl"

[ -f "$LEARNINGS_FILE" ] || exit 0
[ -s "$LEARNINGS_FILE" ] || exit 0

# Read the hook payload from stdin into a variable so we control stdin to python
payload=$(cat)

# Pass payload via env var — avoids stdin collision with heredoc
export HOOK_PAYLOAD="$payload"
export LEARNINGS_PATH="$LEARNINGS_FILE"
export MAX_INJECT=5

python3 <<'PY'
import json, os, re, datetime, math, sys

path = os.environ["LEARNINGS_PATH"]
max_inject = int(os.environ["MAX_INJECT"])
payload_raw = os.environ.get("HOOK_PAYLOAD", "")

try:
    data = json.loads(payload_raw)
    prompt = data.get("prompt", "").lower()
except Exception:
    sys.exit(0)

if len(prompt) < 20:
    sys.exit(0)

tokens = set(re.findall(r'[a-z0-9][a-z0-9-]{2,}', prompt))
STOP = {"the","and","that","this","with","for","from","into","your","have","will","about",
        "what","where","which","should","would","could","implement","create","build","add",
        "use","our","system","need","want"}
tokens -= STOP

if not tokens:
    sys.exit(0)

now = datetime.datetime.utcnow()
scored = []
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("agent") == "bootstrap":
                continue
            blob = " ".join([
                rec.get("task_type",""),
                " ".join(rec.get("tags",[])),
                rec.get("what_worked",""),
                rec.get("what_failed",""),
                rec.get("approach",""),
            ]).lower()
            rec_tokens = set(re.findall(r'[a-z0-9][a-z0-9-]{2,}', blob))
            overlap = len(tokens & rec_tokens)
            if overlap == 0:
                continue
            try:
                ts = datetime.datetime.strptime(rec["ts"], "%Y-%m-%dT%H:%M:%SZ")
                age_days = (now - ts).total_seconds() / 86400
                decay = math.exp(-age_days / 30.0)
            except Exception:
                decay = 0.5
            verified_bonus = 1.3 if rec.get("verified") else 1.0
            score = overlap * decay * verified_bonus
            scored.append((score, rec))
except Exception:
    sys.exit(0)

if not scored:
    sys.exit(0)

scored.sort(key=lambda x: -x[0])
top = scored[:max_inject]

lines = ["📚 RELEVANT PAST LEARNINGS (from claude-dual memory fabric):\n"]
for score, rec in top:
    line = f"- [{rec.get('agent','?')}/{rec.get('task_type','?')}] {rec.get('outcome','?')}"
    ww = rec.get('what_worked','').strip()
    wf = rec.get('what_failed','').strip()
    if ww:
        line += f" — worked: {ww[:200]}"
    if wf:
        line += f" — failed: {wf[:200]}"
    if not rec.get('verified'):
        line += " (unverified)"
    lines.append(line)

lines.append("\nUse these as prior evidence, not gospel. Unverified entries may be wrong — cross-check against current state before acting.")

out = {
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "\n".join(lines)
  }
}
print(json.dumps(out))
PY
