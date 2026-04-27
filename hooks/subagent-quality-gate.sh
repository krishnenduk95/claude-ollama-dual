#!/bin/bash
# subagent-quality-gate: SubagentStop hook. When a GLM subagent finishes,
# inspects its JSON SUMMARY block. If status=failure, injects a retry-signal
# (with fallback model suggestion) into Opus's next turn. One-time per failure
# (retry cap honored). Silent otherwise.
#
# Runs via SubagentStop hook. Must be FAST (<50ms typical). No network calls.
#
# Payload fields consumed:
#   session_id  — session identifier (used for retry-count state filename)
#   subagent_type — "glm-worker", "glm-explorer", etc.
#   transcript_path — path to the session transcript JSONL

set -eu

payload=$(cat)
export HOOK_PAYLOAD="$payload"

python3 <<'PY'
import json, os, sys, hashlib, re
from datetime import datetime, timezone

payload_raw = os.environ.get("HOOK_PAYLOAD", "")
try:
    data = json.loads(payload_raw)
except Exception:
    sys.exit(0)

session_id = data.get("session_id")
subagent_type = data.get("subagent_type")
transcript_path = (
    data.get("transcript_path")
    or data.get("session_transcript_path")
    or data.get("transcript")
    or data.get("transcript_file")
)

# Bail if any required field is missing
if not session_id or not subagent_type or not transcript_path:
    sys.exit(0)

# Only care about GLM subagents
if not subagent_type.startswith("glm-"):
    sys.exit(0)

# Read transcript, extract JSON SUMMARY block from the assistant's last response
summary = None
if os.path.exists(transcript_path):
    try:
        text_parts = []
        with open(transcript_path) as f:
            lines = f.readlines()
        # Walk backward from end, accumulating raw text content
        for line in reversed(lines):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                msg = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            content_blocks = msg.get("content", [])
            if isinstance(content_blocks, list):
                for block in reversed(content_blocks):
                    if isinstance(block, dict) and block.get("type") == "text":
                        text_parts.append(block.get("text", ""))
            total = sum(len(t) for t in text_parts)
            if total >= 2048:
                break
        if not text_parts:
            text_parts = [line.strip() for line in lines[-5:] if line.strip()]
        combined_text = "\n".join(reversed(text_parts))
        tail = combined_text[-4096:] if len(combined_text) > 4096 else combined_text

        # Primary: fenced ```json block containing "subagent" key
        m = re.search(
            r'```json\s*(\{.*?"subagent"\s*:\s*"[^"]+".*?\})\s*```',
            tail, re.DOTALL
        )
        if m:
            try:
                parsed = json.loads(m.group(1))
                if parsed.get("subagent"):
                    summary = parsed
            except json.JSONDecodeError:
                pass
        if not summary:
            # Fallback: outermost JSON object with "subagent" key (unfenced)
            m = re.search(r'\{\s*"subagent"\s*:\s*"', tail)
            if m:
                start = m.start()
                depth = 0
                end = start
                for i, ch in enumerate(tail[start:]):
                    if ch == '{':
                        depth += 1
                    elif ch == '}':
                        depth -= 1
                    if depth == 0:
                        end = start + i + 1
                        break
                if depth == 0:
                    try:
                        parsed = json.loads(tail[start:end])
                        if parsed.get("subagent"):
                            summary = parsed
                    except (json.JSONDecodeError, ValueError):
                        pass
    except Exception:
        pass

if not summary:
    sys.exit(0)

# Only act on failures
status = summary.get("status", "")
if status != "failure":
    sys.exit(0)

key_finding = summary.get("key_finding", "") or ""
# SHA-1 of subagent_type + ":" + key_finding[:100]
truncated = key_finding[:100]
failure_key = hashlib.sha1(f"{subagent_type}:{truncated}".encode()).hexdigest()

# Retry cap: count >= 1 means we already signaled once
scratch_dir = os.path.expanduser("~/.claude-dual/scratch")
os.makedirs(scratch_dir, exist_ok=True)
state_path = os.path.join(scratch_dir, f"{session_id}.retry-count.json")

state = {}
if os.path.exists(state_path):
    try:
        with open(state_path) as f:
            state = json.load(f)
    except Exception:
        state = {}

entry = state.get(failure_key)
if entry and isinstance(entry, dict) and entry.get("count", 0) >= 1:
    sys.exit(0)

# Record this failure
state[failure_key] = {
    "count": 1,
    "last_ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
}
try:
    with open(state_path, "w") as f:
        json.dump(state, f)
except Exception:
    pass

# Look up fallback chain
fallback_text = ""
chains_path = os.path.expanduser("~/.claude-dual/fallback-chains.json")
if os.path.exists(chains_path):
    try:
        with open(chains_path) as f:
            chains = json.load(f)
        chain = chains.get(subagent_type, [])
        if not isinstance(chain, list) or len(chain) == 0:
            fallback_text = "no fallback available — escalate to Opus directly"
        else:
            fallback_text = f"Suggested fallback: re-dispatch as {chain[0]} with the failure context as part of the new brief."
    except Exception:
        fallback_text = "no fallback available — escalate to Opus directly"
else:
    fallback_text = "no fallback available — escalate to Opus directly"

# Build injection message
finding_short = key_finding[:200] if len(key_finding) > 200 else key_finding
msg = (
    f"⚠ SUBAGENT FAILURE — {subagent_type} reported status=failure: "
    f"\"{finding_short}\"\n"
    f"{fallback_text}\n"
    "This is your decision — Opus retains control. Skip if the failure is "
    "acceptable or if context loss outweighs retry value."
)

out = {
    "hookSpecificOutput": {
        "hookEventName": "SubagentStop",
        "additionalContext": msg
    }
}
print(json.dumps(out))
PY
