#!/bin/bash
# deep-reason-detector: scans user prompts for reasoning-heavy patterns
# and injects chain-of-debate + plan-solve-verify instructions into Opus's context.
#
# Fires on UserPromptSubmit. Only emits context when the prompt matches
# reasoning-heavy patterns — stays silent on simple "build X" / "fix Y" / CRUD work.
#
# Injection protocol: hookSpecificOutput.additionalContext (JSON to stdout).
# This is the same pattern as delegation-enforcer.sh v1.5.3.

set -eu

# Read the full hook payload from stdin
payload=$(cat)

# Extract the user's prompt text
prompt=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("prompt", ""))
except Exception:
    pass
' 2>/dev/null || echo "")

# Empty prompt → exit silently
[ -z "$prompt" ] && exit 0

# Lowercase for matching
lower=$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')

# ============================================================
# Pattern matching — reasoning-heavy vs. build/fix/CRUD
# ============================================================
# Trigger chain-of-debate when the prompt asks for:
#   - ranking / comparison / choice between options
#   - tradeoff analysis
#   - "should we X or Y" style decisions
#   - architecture / design decisions with alternatives
#   - capacity planning, library / DB / framework selection
#   - "why is X better than Y" / "what's the right approach"
#
# Do NOT trigger on:
#   - "build X" / "create Y" / "implement Z" / "fix bug"
#   - simple factual lookups ("what does X do?")
#   - debugging ("this is broken, fix it")

trigger=0
reason=""

# Strong triggers — ranking / comparison / tradeoff language
if printf '%s' "$lower" | grep -qE '(which (one )?(is |should |would )?(better|best|right|worse))|(compare|comparison)|(tradeoffs?|trade-offs?)|(pros and cons|pros vs cons)|(rank|ranking)|(evaluate .* (options|alternatives|choices))|(pick between|choose between|decide between)|(.* or .*\?)|(is .* better than .*)|(versus|vs\.? )'; then
  trigger=1
  reason="ranking/comparison/tradeoff language detected"
fi

# Architecture / design-decision language
if printf '%s' "$lower" | grep -qE '(architecture|design) (decision|choice|tradeoff)|(should (we|i|you) (use|pick|choose|go with))|(what.?s the (best|right) (way|approach|choice|option))|(how should (we|i) (architect|design|structure))|(monolith vs|microservice|serverless vs)|(which (database|framework|library|stack))'; then
  trigger=1
  reason="architecture/design decision"
fi

# Capacity / scaling / cost analysis
if printf '%s' "$lower" | grep -qE '(capacity planning|scaling strategy|cost analysis|cost tradeoff)|(will .* scale)|(can .* handle (10|100|1000|10k|100k|1m).*(users|rps|requests))|(what.?s the (cost|price|scaling) (of|for))'; then
  trigger=1
  reason="capacity/scaling/cost analysis"
fi

# Explicit deep-reason invocation (belt-and-suspenders, even without slash command)
if printf '%s' "$lower" | grep -qE '(deep (reason|reasoning|analysis))|(think (hard|deeply|carefully))|(reason (through|about) this (carefully|hard))|(what do you (really )?think)|(give me your (real|honest|deep) (take|opinion|analysis))'; then
  trigger=1
  reason="explicit deep-reasoning request"
fi

# Explicit exclusions — these override triggers (build/fix intent dominates)
if printf '%s' "$lower" | grep -qE '^(build|create|implement|add|write|fix|debug|refactor|rename|move|delete|remove|install|bump|update|upgrade) '; then
  # If the prompt STARTS with an action verb, it's an implementation request.
  # Even if it contains comparison language ("add the better one"), treat as build.
  trigger=0
fi

# Short prompts (<30 chars) are almost always simple queries — skip
[ ${#prompt} -lt 30 ] && trigger=0

# No match → exit silently
[ "$trigger" -eq 0 ] && exit 0

# ============================================================
# Inject chain-of-debate instructions
# ============================================================
read -r -d '' injection <<'MSG' || true
🧠 DEEP-REASONING DETECTED — auto-invoking /deep-reason protocol.

This prompt is reasoning-heavy (ranking / tradeoff / architecture / capacity decision). Do NOT answer off the top of your head. Instead:

1. **Dispatch glm-analyst** (chain-of-debate) with the user's question verbatim. The subagent's system prompt already enforces Candidate A (conservative) / Candidate B (balanced) / Candidate C (aggressive) / Synthesis / Final recommendation.

2. **If the question is architecture-shaped** (service boundaries, tech stack, data model, integration design), ALSO dispatch glm-architect (plan-solve-verify) IN PARALLEL in the same message. Two independent reasoning lines from two different cloud models.

3. **Synthesize** their output yourself (Opus). Identify agreements → high-confidence. Adjudicate disagreements. Add any blind spot present in all candidates. Deliver the final answer with a confidence tag and flip-condition.

If this prompt is actually a simple build/fix request that the detector mis-flagged, ignore this and proceed normally — but err toward dispatching: deep reasoning is the whole point of the stack.
MSG

# Prepend the trigger reason so the user/Opus can see WHY this fired —
# also makes `reason` a live variable instead of a dead store.
injection="(trigger: ${reason})"$'\n'"${injection}"

# Emit hookSpecificOutput JSON (same protocol as delegation-enforcer v1.5.3)
printf '%s' "$injection" | python3 -c '
import json, sys
msg = sys.stdin.read()
out = {
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": msg
    }
}
print(json.dumps(out))
'

exit 0
