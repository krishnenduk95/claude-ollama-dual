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
from collections import defaultdict

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
    model_data = defaultdict(lambda: {"requests":0, "ok":0, "err":0, "sum_dur":0.0, "n_dur":0})

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

    for model, d in model_data.items():
        if d["requests"] < 5:
            continue
        stats["models"][model] = {
          "requests_30d": d["requests"],
          "success_rate": round(d["ok"]/d["requests"], 3) if d["requests"] else None,
          "error_rate":   round(d["err"]/d["requests"], 3) if d["requests"] else None,
          "avg_latency_sec": round(d["sum_dur"]/d["n_dur"], 2) if d["n_dur"] else None,
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

with open(out_path, "w") as f:
    json.dump(stats, f, indent=2)
print(f"routing-stats written: {out_path} ({len(stats['models'])} models, {sum(len(v) for v in stats['agents'].values())} agent-task cells)")
PY
