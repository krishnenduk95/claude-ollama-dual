#!/bin/bash
# best-of-n-detector: UserPromptSubmit hook that suggests /best-of-n
# when the incoming prompt matches hard-task signals where 3-way parallel
# candidates would meaningfully outperform a single shot.
#
# Suggests — does NOT force. Opus still decides whether quota/time budget
# justifies it. Stays silent unless the signal is strong.

set -eu

payload=$(cat)
export HOOK_PAYLOAD="$payload"

python3 <<'PY'
import json, os, re, sys

payload = os.environ.get("HOOK_PAYLOAD", "")
try:
    data = json.loads(payload)
    prompt = data.get("prompt", "").lower()
except Exception:
    sys.exit(0)

if len(prompt) < 40:
    sys.exit(0)

# Skip if user already invoked a slash command or asked for a specific protocol
if prompt.lstrip().startswith(("/", "@")):
    sys.exit(0)
if any(k in prompt[:80] for k in ["best-of-n", "/best-of-n", "bon", "verifier"]):
    sys.exit(0)

# Hard-task signals — each worth some points; need 2+ to trigger
signals = {
    # algorithm-heavy
    "algorithm": 2, "dynamic programming": 3, "graph traversal": 2, "parsing": 2,
    "parser": 2, "dijkstra": 3, "backtracking": 3, "recursion": 1, "tree traversal": 2,
    # concurrency / perf
    "concurren": 3, "race condition": 3, "deadlock": 3, "thread-safe": 2,
    "async ordering": 3, "lock-free": 3, "atomic": 2, "mutex": 2,
    "optimize performance": 2, "reduce latency": 2, "p95": 2, "p99": 2,
    # hard bugs
    "intermittent": 3, "flaky": 2, "heisenbug": 3, "root cause": 2,
    "subtle bug": 3, "memory leak": 3, "off-by-one": 2,
    # refactor scope
    "refactor across": 2, "rename across": 1, "migrate": 1,
    # security / correctness critical
    "security-critical": 3, "crypto": 2, "auth flow": 2,
    "audit-proof": 3, "invariant": 2, "proof of correctness": 3,
    # explicit quality asks
    "highest quality": 3, "best possible": 2, "most correct": 2,
    "can't afford": 2, "production-grade": 1,
}

score = 0
matched = []
for kw, weight in signals.items():
    if kw in prompt:
        score += weight
        matched.append(kw)

# Anti-signals — things that mean "fast, not best"
for anti in ["quick", "prototype", "rough", "draft", "sketch", "throwaway",
             "just get it working", "hack together", "mvp only", "spike"]:
    if anti in prompt:
        score -= 3

if score < 4:
    sys.exit(0)

msg = (
  "⚡ BEST-OF-N CANDIDATE: the incoming task shows "
  f"{len(matched)} hard-task signals ({', '.join(matched[:5])}). "
  "If correctness dominates cost here, consider invoking /best-of-n — "
  "dispatch glm-worker 3× with varied approaches, score with glm-reviewer, "
  "merge the winner. Skip if this is a prototype, a trivial edit, or quota-constrained."
)

out = {
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": msg
  }
}
print(json.dumps(out))
PY
