#!/bin/bash
# compute-routing-stats: aggregate audit.jsonl (latency/errors) + learnings.jsonl
# (outcomes) into per-agent-per-task-type win-rates and per-model reliability.
#
# Run on-demand (from SessionStart) or via cron. Writes routing-stats.json —
# the session-start injector reads this and shows Opus the current picture.

set -eu

AUDIT="${HOME}/.claude-dual/audit.jsonl"
LEARNINGS="${HOME}/.claude-dual/memory/learnings.jsonl"
OUT="${HOME}/.claude-dual/routing-stats.json"

python3 <<PY
import json, os, datetime, math
from collections import defaultdict, deque

audit_path = "$AUDIT"
learnings_path = "$LEARNINGS"
out_path = "$OUT"

now = datetime.datetime.utcnow()
stats = {
  "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
  "audit_window_days": 30,
  "models": {},
  "agents": {},
}

# ── Per-model stats from audit.jsonl (latency, error rate) ─────────
if os.path.exists(audit_path):
    pending = {}  # request_id → {ts, model, provider}
    model_data = defaultdict(lambda: {"requests":0, "ok":0, "err":0, "sum_dur":0.0, "n_dur":0, "durations": deque(maxlen=50)})

    with open(audit_path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except Exception:
                continue
            try:
                ts = datetime.datetime.strptime(e["ts"][:19], "%Y-%m-%dT%H:%M:%S")
            except Exception:
                continue
            if (now - ts).days > 30:
                continue
            rid = e.get("request_id")
            if e.get("event") == "request" and rid:
                pending[rid] = {"model": e.get("model") or "", "provider": e.get("provider") or "", "path": e.get("path","")}
            elif e.get("event") in ("request_end", "request_failed") and rid:
                meta = pending.pop(rid, None)
                if meta is None:
                    continue
                model = meta["model"] or "unknown"
                if not model or meta.get("path","").endswith("/") or meta.get("path") == "/":
                    # health checks — skip
                    continue
                m = model_data[model]
                m["requests"] += 1
                status = e.get("status", 0)
                dur = e.get("duration_sec")
                if isinstance(dur, (int,float)):
                    m["sum_dur"] += dur
                    m["n_dur"] += 1
                if e.get("event") == "request_failed" or (isinstance(status,int) and status >= 500):
                    m["err"] += 1
                elif isinstance(status,int) and 200 <= status < 400:
                    m["ok"] += 1
                    if isinstance(dur, (int,float)):
                        m["durations"].append(dur)

    for model, d in model_data.items():
        if d["requests"] < 5:
            continue
        # p50/p95 from last 50 successful durations
        dur_list = list(d["durations"])
        if len(dur_list) >= 5:
            sorted_durs = sorted(dur_list)
            n = len(sorted_durs)
            p50 = round(sorted_durs[n // 2], 2)
            p95 = round(sorted_durs[int(math.ceil(n * 0.95)) - 1], 2)
        else:
            p50 = p95 = None
        stats["models"][model] = {
          "requests_30d": d["requests"],
          "success_rate": round(d["ok"]/d["requests"], 3) if d["requests"] else None,
          "error_rate":   round(d["err"]/d["requests"], 3) if d["requests"] else None,
          "avg_latency_sec": round(d["sum_dur"]/d["n_dur"], 2) if d["n_dur"] else None,
          "p50_latency_sec": p50,
          "p95_latency_sec": p95,
        }

# ── Per-agent per-task-type win-rates from learnings.jsonl ─────────
if os.path.exists(learnings_path):
    agent_task = defaultdict(lambda: defaultdict(lambda: {"success":0,"partial":0,"failure":0,"total":0,"verified":0}))
    with open(learnings_path) as f:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                continue
            agent = r.get("agent")
            task  = r.get("task_type")
            out   = r.get("outcome")
            if not agent or not task or agent == "bootstrap":
                continue
            try:
                ts = datetime.datetime.strptime(r["ts"], "%Y-%m-%dT%H:%M:%SZ")
                if (now - ts).days > 90:
                    continue
            except Exception:
                pass
            rec = agent_task[agent][task]
            rec["total"] += 1
            if r.get("verified"):
                rec["verified"] += 1
            if out == "success":
                rec["success"] += 1
            elif out == "partial":
                rec["partial"] += 1
            elif out == "failure":
                rec["failure"] += 1

    for agent, tasks in agent_task.items():
        stats["agents"][agent] = {}
        for task, d in tasks.items():
            if d["total"] < 2:
                continue
            stats["agents"][agent][task] = {
              "total": d["total"],
              "success_rate": round(d["success"]/d["total"], 3),
              "partial_rate": round(d["partial"]/d["total"], 3),
              "failure_rate": round(d["failure"]/d["total"], 3),
              "verified_count": d["verified"],
            }

# ── Per-agent per-task-type success rates from audit.jsonl task_type ──
# Maps Ollama model to its primary agent (first in the subagent pool)
MODEL_PRIMARY_AGENT = {
    "glm-5.1:cloud": "glm-architect",
    "deepseek-v4-flash:cloud": "glm-worker",
    "kimi-k2.5:cloud": "glm-explorer",
    "qwen3-coder-next:cloud": "glm-test-generator",
}
TASK_TYPE_AGENT_OVERRIDE = {
    "implementation": "glm-worker",
    "refactor": "glm-worker",
    "exploration": "glm-explorer",
    "review": "glm-reviewer",
    "security-audit": "glm-security-auditor",
    "architecture": "glm-architect",
    "api-design": "glm-api-designer",
    "ui-component": "glm-ui-builder",
    "test-generation": "glm-test-generator",
}

def _model_to_agent(model, task_type):
    if task_type in TASK_TYPE_AGENT_OVERRIDE:
        return TASK_TYPE_AGENT_OVERRIDE[task_type]
    if model in MODEL_PRIMARY_AGENT:
        return MODEL_PRIMARY_AGENT[model]
    return "glm-worker"  # fallback

task_type_data = defaultdict(lambda: defaultdict(
    lambda: {"n":0, "successes":0, "total_latency":0.0}
))

if os.path.exists(audit_path):
    with open(audit_path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("event") not in ("request_end", "request_failed"):
                continue
            provider = e.get("provider", "") or ""
            if provider != "ollama":
                continue
            tt = e.get("task_type")
            if not tt or not isinstance(tt, str) or not tt.strip():
                continue
            tt = tt.strip()
            model = e.get("model", "") or ""
            agent = _model_to_agent(model, tt)
            status = e.get("status", 0)
            sq = e.get("subagent_quality")
            success = (
                (isinstance(status, int) and status == 200)
                or sq is None or sq == "healthy"
            )
            dur = e.get("duration_sec", 0)
            if not isinstance(dur, (int, float)):
                dur = 0.0
            ttd = task_type_data[agent][tt]
            ttd["n"] += 1
            if success:
                ttd["successes"] += 1
            ttd["total_latency"] += dur

# Merge into stats["agents"]
for agent, task_types in task_type_data.items():
    if agent not in stats["agents"]:
        stats["agents"][agent] = {}
    task_type_summary = {}
    for task_type, d in task_types.items():
        entry = {
            "n": d["n"],
            "success_rate": round(d["successes"]/d["n"], 3) if d["n"] else 0.0,
            "avg_latency_sec": round(d["total_latency"]/d["n"], 2) if d["n"] else None,
        }
        if d["n"] < 5:
            entry["cold_start"] = True
        task_type_summary[task_type] = entry
    stats["agents"][agent]["task_types"] = task_type_summary

with open(out_path, "w") as f:
    json.dump(stats, f, indent=2)
print(f"routing-stats written: {out_path} ({len(stats['models'])} models, {sum(len(v) for v in stats['agents'].values())} agent-task cells)")
PY
