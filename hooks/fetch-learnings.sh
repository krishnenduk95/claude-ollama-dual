#!/bin/bash
# fetch-learnings: UserPromptSubmit hook that finds the N most relevant
# past learnings and injects them as additionalContext.
#
# Relevance = keyword overlap between the incoming prompt and each
# learning's task_type + tags + what_worked/what_failed text.
# Time-decay weighting: recent entries score higher.

set -eu

LEARNINGS_FILE="${HOME}/.claude-dual/memory/learnings.jsonl"

# Read the hook payload from stdin into a variable so we control stdin to python
payload=$(cat)

# Pass payload via env var — avoids stdin collision with heredoc
export HOOK_PAYLOAD="$payload"
export LEARNINGS_PATH="$LEARNINGS_FILE"
export MAX_INJECT=3
export LEARNINGS_MIN_SCORE="${LEARNINGS_MIN_SCORE:-0.15}"

python3 <<'PY'
import json, os, re, datetime, math, sys

path = os.environ.get("LEARNINGS_PATH", "")
max_inject = int(os.environ.get("MAX_INJECT", "3"))
min_score = float(os.environ.get("LEARNINGS_MIN_SCORE") or "0.15")
payload_raw = os.environ.get("HOOK_PAYLOAD", "")

learnings_text = ""

try:
    data = json.loads(payload_raw)
    prompt = data.get("prompt", "").lower()
except Exception:
    data = {}
    prompt = ""

# --- LEARNINGS ---
if path and os.path.exists(path) and os.path.getsize(path) > 0 and len(prompt) >= 20:
    tokens = set(re.findall(r'[a-z0-9][a-z0-9-]{2,}', prompt))
    STOP = {"the","and","that","this","with","for","from","into","your","have","will","about",
            "what","where","which","should","would","could","implement","create","build","add",
            "use","our","system","need","want"}
    tokens -= STOP

    if tokens:
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
            pass

        if scored:
            scored.sort(key=lambda x: -x[0])
            top = [(s, r) for s, r in scored if s >= min_score][:max_inject]
            if top:
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
                learnings_text = "\n".join(lines)

# --- SCRATCH ---
scratch_text = ""
session_id = data.get("session_id", "default") if isinstance(data, dict) else "default"
scratch_dir = os.path.expanduser("~/.claude-dual/scratch")
scratch_path = os.path.join(scratch_dir, f"{session_id}.jsonl")
if os.path.exists(scratch_path):
    try:
        with open(scratch_path) as sf:
            scratch_entries = [json.loads(l) for l in sf if l.strip()]
        last_3 = scratch_entries[-3:]
        if last_3:
            parts = ["RECENT SUBAGENT OUTPUT (this session):"]
            for rec in last_3:
                entry_line = f"- {rec.get('subagent','?')}/{rec.get('task_type','?')}: {rec.get('status','?')} — {rec.get('key_finding','')[:120]}"
                parts.append(entry_line)
            scratch_text = "\n".join(parts)
            if len(scratch_text) > 500:
                scratch_text = scratch_text[:497] + "..."
    except Exception:
        pass

# --- COMBINE ---
if not learnings_text and not scratch_text:
    sys.exit(0)

combined = learnings_text
if learnings_text and scratch_text:
    combined += "\n\n" + scratch_text
elif scratch_text:
    combined = scratch_text

out = {
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": combined
  }
}
print(json.dumps(out))
PY
