#!/bin/bash
# compute-quota: roll up audit.jsonl into per-provider per-day request counts +
# 7-day rolling totals. Writes quota.json — the session-start injector & the
# best-of-n-detector read this to decide whether to warn or gate dispatches.
#
# Quota model (conservative defaults — tune in ~/.claude-dual/quota-limits.json):
#   - ollama (Ollama Cloud / GLM): 1200 requests / rolling-7-day window
#   - anthropic (Claude Max): 4500 messages / rolling-7-day window
# Override by writing: {"ollama":{"weekly":2000},"anthropic":{"weekly":5000}}

set -eu

AUDIT="${HOME}/.claude-dual/audit.jsonl"
LIMITS="${HOME}/.claude-dual/quota-limits.json"
OUT="${HOME}/.claude-dual/quota.json"

[ -f "$AUDIT" ] || { echo '{"error":"no audit log"}' > "$OUT"; exit 0; }

python3 <<PY
import json, os, datetime
from collections import defaultdict

audit = "$AUDIT"
limits_path = "$LIMITS"
out = "$OUT"

# Defaults — deliberately high so the warning only fires on real overuse.
# Users with tighter plans override via ~/.claude-dual/quota-limits.json.
# If that file doesn't exist, we self-calibrate after first week: take the
# max of defaults and 1.5× observed 7d usage, so "normal" never trips.
limits = {"ollama": {"weekly": 14000}, "anthropic": {"weekly": 4500}}
user_configured = False
if os.path.exists(limits_path):
    try:
        user_limits = json.load(open(limits_path))
        user_configured = True
        for k, v in user_limits.items():
            if isinstance(v, dict):
                limits.setdefault(k, {}).update(v)
    except Exception:
        pass

now = datetime.datetime.utcnow()
today = now.date()
week_ago = now - datetime.timedelta(days=7)

# provider → date (YYYY-MM-DD) → count
daily = defaultdict(lambda: defaultdict(int))
weekly = defaultdict(int)

with open(audit) as f:
    for line in f:
        try:
            e = json.loads(line)
        except Exception:
            continue
        if e.get("event") != "request":
            continue
        provider = e.get("provider") or "unknown"
        if not provider or provider == "unknown":
            continue
        try:
            ts = datetime.datetime.strptime(e["ts"][:19], "%Y-%m-%dT%H:%M:%S")
        except Exception:
            continue
        d = ts.date()
        if (now - ts).days <= 30:
            daily[provider][d.isoformat()] += 1
        if ts >= week_ago:
            weekly[provider] += 1

result = {
    "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "providers": {},
}

# Auto-calibrate: if user hasn't set custom limits AND observed usage already
# exceeds defaults, bump the default so steady-state usage doesn't trip.
# This is pure heuristic — user should still tune quota-limits.json to match
# their real plan, but this prevents spam warnings on first few sessions.
if not user_configured:
    for provider, wk in weekly.items():
        lim = limits.get(provider, {}).get("weekly")
        if lim and wk > lim * 0.8:
            limits.setdefault(provider, {})["weekly"] = int(wk * 1.5)
            limits[provider]["_auto_calibrated"] = True

for provider, dmap in daily.items():
    wk = weekly.get(provider, 0)
    lim = limits.get(provider, {}).get("weekly")
    pct = round(wk / lim * 100, 1) if lim else None
    status = "ok"
    if pct is not None:
        if pct >= 95:
            status = "exhausted"
        elif pct >= 80:
            status = "warning"
    result["providers"][provider] = {
        "weekly_used": wk,
        "weekly_limit": lim,
        "weekly_pct": pct,
        "status": status,
        "auto_calibrated": limits.get(provider, {}).get("_auto_calibrated", False),
        "today": dmap.get(today.isoformat(), 0),
        "daily_7d": [
            {"date": (today - datetime.timedelta(days=i)).isoformat(),
             "count": dmap.get((today - datetime.timedelta(days=i)).isoformat(), 0)}
            for i in range(6, -1, -1)
        ],
    }

with open(out, "w") as f:
    json.dump(result, f, indent=2)
print(f"quota written: {out}")
for p, d in result["providers"].items():
    print(f"  {p}: {d['weekly_used']}/{d['weekly_limit']} ({d['weekly_pct']}%) — {d['status']}")
PY
