#!/bin/bash
# adaptive-routing-hint: UserPromptSubmit hook. Detects task-type keywords
# in the prompt, looks up routing-stats.json.agents, emits a hint when 2+
# agents have data for the matched task type (n >= 5).
#
# Silent exit when:
#   - prompt is too short / no keyword matched
#   - quota is warning or exhausted
#   - fewer than 2 agents have data
#   - required files are missing
#
set -eu

payload=$(cat)
export HOOK_PAYLOAD="$payload"

python3 <<'PY'
import json, os, sys, re

payload_raw = os.environ.get("HOOK_PAYLOAD", "")

# ── Parse payload ────────────────────────────────────────────────────────
try:
    data = json.loads(payload_raw)
except Exception:
    sys.exit(0)
prompt = data.get("prompt", "")
if not prompt or len(prompt) < 30:
    sys.exit(0)
prompt_lower = prompt.lower()

# ── Quota check: silent exit if any provider warning/exhausted ────────────
quota_path = os.path.expanduser("~/.claude-dual/quota.json")
if os.path.exists(quota_path):
    try:
        with open(quota_path) as f:
            quota = json.load(f)
        providers = quota.get("providers", {})
        for pname, pinfo in providers.items():
            status = pinfo.get("status", "")
            if status in ("warning", "exhausted"):
                sys.exit(0)
    except Exception:
        pass

# ── Keyword → task_type map ──────────────────────────────────────────────
KEYWORD_MAP = {
    "implement": "implementation",
    "build": "implementation",
    "create": "implementation",
    "refactor": "refactor",
    "rename": "refactor",
    "explore": "exploration",
    "find where": "exploration",
    "trace": "exploration",
    "review": "review",
    "audit": "security-audit",
    "security": "security-audit",
    "design": "architecture",
    "architecture": "architecture",
    "test": "test-generation",
    "ui": "ui-component",
    "component": "ui-component",
    "api": "api-design",
    "endpoint": "api-design",
}

matched_type = None
for keyword, task_type in KEYWORD_MAP.items():
    if keyword in prompt_lower:
        matched_type = task_type
        break

if not matched_type:
    sys.exit(0)

# ── Read routing-stats.json ──────────────────────────────────────────────
stats_path = os.path.expanduser("~/.claude-dual/routing-stats.json")
if not os.path.exists(stats_path):
    sys.exit(0)

try:
    with open(stats_path) as f:
        stats = json.load(f)
except Exception:
    sys.exit(0)

agents = stats.get("agents", {})
if not agents:
    sys.exit(0)

# ── Collect agents with data for matched task_type ───────────────────────
candidates = []
for agent_name, agent_info in agents.items():
    if not isinstance(agent_info, dict):
        continue
    task_types = agent_info.get("task_types", {})
    if not isinstance(task_types, dict):
        continue
    tt_info = task_types.get(matched_type)
    if not tt_info or not isinstance(tt_info, dict):
        continue
    n = tt_info.get("n", 0)
    if not isinstance(n, int) or n < 5:
        continue
    success_rate = tt_info.get("success_rate")
    if not isinstance(success_rate, (int, float)):
        continue
    avg_lat = tt_info.get("avg_latency_sec")
    if not isinstance(avg_lat, (int, float)):
        avg_lat = 999999.0
    candidates.append({
        "agent": agent_name,
        "success_rate": float(success_rate),
        "avg_latency_sec": float(avg_lat),
        "n": n,
    })

if len(candidates) < 2:
    sys.exit(0)

# ── Sort: success_rate desc, then avg_latency_sec asc ────────────────────
candidates.sort(key=lambda x: (-x["success_rate"], x["avg_latency_sec"]))

# ── Build hint text (top 3) ──────────────────────────────────────────────
top3 = candidates[:3]
lines = [
    "",
    "ROUTING HINT (last 30d): for " + matched_type + "-shaped tasks:",
]
for c in top3:
    lat_str = ("%ds" % c["avg_latency_sec"]) if c["avg_latency_sec"] < 999999 else "?"
    pct = int(round(c["success_rate"] * 100))
    lines.append("  - " + c["agent"] + ": " + str(pct) + "% success (n=" + str(c["n"]) + "), avg " + lat_str)

best = top3[0]["agent"]
lines.append("Suggestion: prefer " + best + ". Override if you need agent-specific capabilities.")
lines.append("")

hint_text = "\n".join(lines)

# ── Emit hook output ─────────────────────────────────────────────────────
out = {
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": hint_text,
    }
}
print(json.dumps(out))
PY
