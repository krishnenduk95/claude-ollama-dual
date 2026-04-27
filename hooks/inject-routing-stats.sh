#!/bin/bash
# inject-routing-stats: SessionStart hook. Refreshes routing-stats.json
# (cheap — parses ~17k lines in <200ms) and injects a compact summary
# as additionalContext so Opus's dispatch decisions see live win-rates.

set -eu

STATS_FILE="${HOME}/.claude-dual/routing-stats.json"
COMPUTE_SCRIPT="${HOME}/.claude-dual/compute-routing-stats.sh"
QUOTA_FILE="${HOME}/.claude-dual/quota.json"
QUOTA_SCRIPT="${HOME}/.claude-dual/compute-quota.sh"

# Refresh stats if script exists and file is missing or older than 1 hour
if [ -x "$COMPUTE_SCRIPT" ]; then
  if [ ! -f "$STATS_FILE" ] || [ "$(find "$STATS_FILE" -mmin +60 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
    "$COMPUTE_SCRIPT" >/dev/null 2>&1 || true
  fi
fi
# Refresh quota (cheaper — do it every session start)
if [ -x "$QUOTA_SCRIPT" ]; then
  "$QUOTA_SCRIPT" >/dev/null 2>&1 || true
fi

[ -f "$STATS_FILE" ] || exit 0
[ -s "$STATS_FILE" ] || exit 0

python3 <<PY
import json, os, sys

path = "$STATS_FILE"
quota_path = "$QUOTA_FILE"
try:
    with open(path) as f:
        stats = json.load(f)
except Exception:
    sys.exit(0)

models = stats.get("models", {})
agents = stats.get("agents", {})
if not models and not agents:
    sys.exit(0)

lines = ["📊 LIVE ROUTING STATS (from ~/.claude-dual/routing-stats.json, last 30d audit + 90d learnings):\n"]

if models:
    lines.append("Model reliability:")
    sorted_models = sorted(models.items(), key=lambda x: -x[1].get("requests_30d",0))
    for name, d in sorted_models[:6]:
        sr = d.get("success_rate")
        er = d.get("error_rate")
        lat = d.get("avg_latency_sec")
        p50 = d.get("p50_latency_sec")
        p95 = d.get("p95_latency_sec")
        n = d.get("requests_30d")
        sr_str = f"{sr*100:.0f}%" if sr is not None else "?"
        er_str = f"{er*100:.1f}%" if er is not None else "?"
        if p50 is not None and p95 is not None:
            lat_str = f"p50 {p50}s p95 {p95}s"
        else:
            lat_str = f"avg {lat}s" if lat is not None else "?"
        lines.append(f"  - {name}: success {sr_str}, {lat_str}, err {er_str} over {n} req")

if agents:
    lines.append("\nAgent win-rates by task type (sample size ≥ 2):")
    for agent, tasks in agents.items():
        if not tasks:
            continue
        # Show best + worst 2 task types per agent
        sorted_tasks = sorted(tasks.items(), key=lambda x: x[1]["success_rate"], reverse=True)
        best = sorted_tasks[:2]
        worst = [t for t in sorted_tasks[-2:] if t[1]["success_rate"] < 0.8]
        cells = []
        for task, d in best:
            cells.append(f"{task}={d['success_rate']*100:.0f}% (n={d['total']})")
        for task, d in worst:
            if (task, d) not in best:
                cells.append(f"⚠ {task}={d['success_rate']*100:.0f}% (n={d['total']})")
        if cells:
            lines.append(f"  {agent}: " + ", ".join(cells))

lines.append("\nUse these as a prior when choosing which subagent to dispatch. Low-sample cells (n<5) are suggestive, not conclusive. Anything flagged ⚠ (success <80%) warrants extra Opus review before accepting the output.")

# Quota budget summary — surface warnings/exhausted states so Opus adjusts dispatch strategy.
try:
    if os.path.exists(quota_path):
        with open(quota_path) as f:
            q = json.load(f)
        providers = q.get("providers", {})
        if providers:
            quota_lines = ["\n💰 QUOTA BUDGET (rolling 7d, from ~/.claude-dual/quota.json):"]
            for p, d in providers.items():
                used = d.get("weekly_used", 0)
                lim  = d.get("weekly_limit")
                pct  = d.get("weekly_pct")
                status = d.get("status", "ok")
                today = d.get("today", 0)
                calibrated = d.get("auto_calibrated", False)
                lim_str = str(lim) if lim else "?"
                pct_str = f"{pct}%" if pct is not None else "?"
                cal_str = " [auto-calibrated]" if calibrated else ""
                emoji = {"ok":"🟢","warning":"🟡","exhausted":"🔴"}.get(status,"⚪")
                quota_lines.append(f"  {emoji} {p}: {used}/{lim_str} used ({pct_str}){cal_str} — today {today} — status {status}")
            quota_lines.append("  Guidance: at 🟡 warning (≥80%), avoid /best-of-n multi-sample dispatches. At 🔴 exhausted (≥95%), defer non-urgent delegations to the provider and/or switch to the other provider where possible. Tune ~/.claude-dual/quota-limits.json to match your actual plan limits.")
            lines.extend(quota_lines)
except Exception:
    pass

out = {
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "\n".join(lines)
  }
}
print(json.dumps(out))
PY
