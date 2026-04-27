#!/bin/bash
# live-stats: terminal dashboard for claude-dual proxy.
# Polls /health, /cost, /metrics, ~/.claude-dual/quota.json, routing-stats.json,
# audit.jsonl. Refreshes every 2s. Press q to quit.
#
# Usage:    ~/.claude-dual/live-stats.sh
# Override: PROXY_HOST=127.0.0.1 PROXY_PORT=3456 ~/.claude-dual/live-stats.sh

set -u

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-3456}"
PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"

QUOTA_FILE="${HOME}/.claude-dual/quota.json"
ROUTING_FILE="${HOME}/.claude-dual/routing-stats.json"
AUDIT_FILE="${HOME}/.claude-dual/audit.jsonl"

# ── ANSI / tput ──────────────────────────────────────────────────────────
G=$'\033[32m'  # green
Y=$'\033[33m'  # yellow
R=$'\033[31m'  # red
D=$'\033[2m'   # dim
B=$'\033[1m'   # bold
N=$'\033[0m'   # reset

cleanup() {
  tput cnorm 2>/dev/null   # show cursor
  tput sgr0  2>/dev/null   # reset attrs
  echo
  exit 0
}
trap cleanup INT TERM EXIT

# ── Renderer ─────────────────────────────────────────────────────────────
render() {
  local now health ready cost quota routing events
  now=$(date '+%Y-%m-%d %H:%M:%S')
  health=$(curl -s --max-time 1 "${PROXY_URL}/health" 2>/dev/null || echo '')
  ready=$(curl -s --max-time 1 "${PROXY_URL}/readyz" 2>/dev/null || echo '')
  cost=$(curl -s --max-time 1 "${PROXY_URL}/cost" 2>/dev/null || echo '')
  quota=$(cat "$QUOTA_FILE" 2>/dev/null || echo '{}')
  routing=$(cat "$ROUTING_FILE" 2>/dev/null || echo '{}')
  events=$(tail -100 "$AUDIT_FILE" 2>/dev/null | grep '"event":"request_end"' | tail -5)

  tput cup 0 0
  tput ed

  if [ -z "$health" ]; then
    printf "%sclaude-dual%s ─ live (refresh 2s, q=quit)%${N}%50s%s%s\n\n" "$B" "$N" " " "$D$now$N" ""
    printf "  %sproxy unreachable at %s — retrying...%s\n" "$R" "$PROXY_URL" "$N"
    return
  fi

  PROXY_URL="$PROXY_URL" health="$health" ready="$ready" cost="$cost" quota="$quota" \
    routing="$routing" events="$events" now="$now" \
    G="$G" Y="$Y" R="$R" D="$D" B="$B" N="$N" \
    python3 <<'PY'
import json, os, sys

def env(k): return os.environ.get(k, '')
G,Y,R,D,B,N = env('G'),env('Y'),env('R'),env('D'),env('B'),env('N')

def load(s):
    try: return json.loads(s) if s else {}
    except Exception: return {}

health  = load(env('health'))
ready   = load(env('ready'))
cost    = load(env('cost'))
quota   = load(env('quota'))
routing = load(env('routing'))
now     = env('now')

def color_state(state):
    if state == 'closed': return f"{G}closed{N}"
    if state == 'open':   return f"{R}open{N}"
    return f"{Y}{state}{N}"

def color_status(s):
    if s == 'ok':       return f"{G}🟢 ok{N}"
    if s == 'warning':  return f"{Y}🟡 warn{N}"
    if s == 'exhausted':return f"{R}🔴 exhausted{N}"
    return f"{D}{s}{N}"

# ── header ──────────────────────────────────────────────────────────────
print(f"{B}claude-dual{N} ─ live (refresh 2s, q=quit){'':<28}{D}{now}{N}")
print()

# ── circuits + outage ───────────────────────────────────────────────────
circuits = ready.get('circuits', {})  # /readyz holds circuit state
outage   = health.get('ollama_outage', {})
a_state  = circuits.get('anthropic', '?')
o_state  = circuits.get('ollama', '?')
out_active = outage.get('active', False)
out_since  = outage.get('since') or '—'

print(f"{B}CIRCUITS{N}{'':<37}{B}OUTAGE{N}")
print(f"  anthropic: {color_state(a_state):<24}    ollama: " + (
    f"{R}active since {out_since}{N}" if out_active else f"{G}clear{N}"))
print(f"  ollama:    {color_state(o_state)}")
print()

# ── quota ──────────────────────────────────────────────────────────────
print(f"{B}QUOTA (rolling 7d){N}")
providers = quota.get('providers', {}) or {}
for prov in ('anthropic', 'ollama'):
    q = providers.get(prov, {}) or {}
    used  = q.get('weekly_used', 0)
    limit = q.get('weekly_limit', 0)
    today = q.get('today', 0)
    pct   = q.get('weekly_pct', (100*used/limit) if limit else 0.0)
    status = q.get('status', '?')
    print(f"  {prov:<10} {used:>5} / {limit:<5} used ({pct:>4.1f}%)  today {today:<5}  {color_status(status)}")
print()

# ── cost ──────────────────────────────────────────────────────────────
total = cost.get('total_usd', 0)
limit = cost.get('daily_limit_usd', 0)
print(f"{B}COST TODAY{N} (${total:.2f} / ${limit:.2f} limit)")
by_model = cost.get('by_model', {}) or {}
for m, usd in sorted(by_model.items(), key=lambda x: -x[1]):
    color = R if usd > limit*0.8 else (Y if usd > limit*0.5 else N)
    print(f"  {m:<24} {color}${usd:>6.2f}{N}")
if not by_model:
    print(f"  {D}no spend yet today{N}")
print()

# ── models ──────────────────────────────────────────────────────────────
print(f"{B}MODELS{N}")
print(f"  {'model':<28} {'state':<7} {'p50':>8} {'p95':>8} {'30d_req':>8} {'err':>5}")
print(f"  {'─'*28} {'─'*7} {'─'*8} {'─'*8} {'─'*8} {'─'*5}")

models = routing.get('models', {}) or {}
known = ['claude-opus-4-7', 'deepseek-v4-flash:cloud', 'glm-5.1:cloud',
         'kimi-k2.5:cloud', 'qwen3-coder-next:cloud']
seen = set()
def fmt_lat(v):
    if v is None: return f"{D}—{N}"
    return f"{v:.2f}s"

def state_for(m, info):
    err = info.get('error_rate', 0) or 0
    if err > 0.15: return f"{R}degraded{N}"
    if err > 0.05: return f"{Y}flaky{N}"
    return f"{G}ok{N}"

# print known models first in canonical order
for m in known:
    info = models.get(m, {}) or {}
    seen.add(m)
    p50 = info.get('p50_latency_sec'); p95 = info.get('p95_latency_sec')
    req = info.get('requests_30d', 0); err = info.get('error_rate', 0) or 0
    state = state_for(m, info)
    p50s = f"{p50:>7.2f}s" if isinstance(p50,(int,float)) else f"{D}{'—':>8}{N}"
    p95s = f"{p95:>7.2f}s" if isinstance(p95,(int,float)) else f"{D}{'—':>8}{N}"
    print(f"  {m:<28} {state:<16} {p50s} {p95s} {req:>8} {err*100:>4.0f}%")
# any remaining
for m, info in models.items():
    if m in seen: continue
    p50 = info.get('p50_latency_sec'); p95 = info.get('p95_latency_sec')
    req = info.get('requests_30d', 0); err = info.get('error_rate', 0) or 0
    state = state_for(m, info)
    p50s = f"{p50:>7.2f}s" if isinstance(p50,(int,float)) else f"{D}{'—':>8}{N}"
    p95s = f"{p95:>7.2f}s" if isinstance(p95,(int,float)) else f"{D}{'—':>8}{N}"
    print(f"  {m:<28} {state:<16} {p50s} {p95s} {req:>8} {err*100:>4.0f}%")
print()

# ── recent events ──────────────────────────────────────────────────────
print(f"{B}LAST 5 EVENTS{N} {D}(audit.jsonl){N}")
for line in env('events').splitlines():
    try:
        e = json.loads(line)
    except Exception: continue
    ts = e.get('ts', '')[11:19]  # HH:MM:SS
    ev = e.get('event','')
    p  = e.get('provider','')
    m  = e.get('model','')
    st = e.get('status', '')
    dur = e.get('duration_sec', 0)
    color = G if isinstance(st,int) and 200 <= st < 300 else (R if isinstance(st,int) and st >= 400 else N)
    print(f"  {D}{ts}{N} {ev:<13} {p:<10} {m:<28} {color}status={st}{N} duration={dur}s")
PY
}

# ── Main loop ────────────────────────────────────────────────────────────
tput civis 2>/dev/null
clear
while true; do
  render
  # Read with 2s timeout. -N 1 reads exactly 1 char without waiting for newline.
  # bash 3.2 (macOS) supports -N.
  if read -rsN 1 -t 2 key 2>/dev/null; then
    case "$key" in
      q|Q) cleanup ;;
    esac
  fi
done
