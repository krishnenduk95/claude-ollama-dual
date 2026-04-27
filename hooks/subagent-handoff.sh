#!/bin/bash
# subagent-handoff: SubagentStop hook. When a subagent finishes, look at
# its JSON SUMMARY block in the transcript, record key info to a
# session-level scratch file, so subsequent dispatches can build on
# previous subagent output.
#
# Runs via SubagentStop hook before plan-drift.sh.

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
subagent_type = data.get("subagent_type") or data.get("agent_type") or ""
transcript_path = (
    data.get("transcript_path")
    or data.get("session_transcript_path")
    or data.get("transcript")
    or data.get("transcript_file")
)

# session_id may be missing — fall back to cwd hash
if not session_id:
    cwd = os.getcwd()
    session_id = hashlib.md5(cwd.encode()).hexdigest()[:12]

# Bail if subagent type or transcript path is missing
if not subagent_type or not transcript_path:
    sys.exit(0)

# Only care about GLM subagents that produce JSON SUMMARY blocks
if not subagent_type.startswith("glm-"):
    sys.exit(0)

# Read transcript, parse JSON SUMMARY from the assistant's last response.
# Transcript is JSONL — each line is a JSON object with potentially
# JSON-escaped text. We parse lines, extract text content, then search
# the unescaped text for the JSON SUMMARY block.
summary = None
if os.path.exists(transcript_path):
    try:
        # Read last ~20 lines (JSONL lines can be long)
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
            # Walk message content for text
            content_blocks = msg.get("content", [])
            if isinstance(content_blocks, list):
                for block in reversed(content_blocks):
                    if isinstance(block, dict) and block.get("type") == "text":
                        text_parts.append(block.get("text", ""))
            # Stop when we've accumulated ~2KB of decoded text
            total = sum(len(t) for t in text_parts)
            if total >= 2048:
                break
        if not text_parts:
            # Fallback: search raw content
            text_parts = [line.strip() for line in lines[-5:] if line.strip()]
        combined_text = "\n".join(reversed(text_parts))
        tail = combined_text[-4096:] if len(combined_text) > 4096 else combined_text

        # Primary: look for ```json\n{...}\n``` fenced block
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
            # Fallback: outermost JSON object containing "subagent" key
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

# Build flattened record
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

files_touched = summary.get("files_touched", [])
if not isinstance(files_touched, list):
    files_touched = []
elif len(files_touched) > 5:
    files_touched = files_touched[:5]

key_finding = summary.get("key_finding", "") or ""
if len(key_finding) > 200:
    key_finding = key_finding[:197] + "..."

record = {
    "ts": now,
    "subagent": summary.get("subagent", subagent_type),
    "task_type": summary.get("task_type", ""),
    "status": summary.get("status", "unknown"),
    "key_finding": key_finding,
    "files_touched": files_touched
}

# Persist to scratch file (resilient: failures silently ignored)
try:
    scratch_dir = os.path.expanduser("~/.claude-dual/scratch")
    os.makedirs(scratch_dir, exist_ok=True)

    scratch_path = os.path.join(scratch_dir, f"{session_id}.jsonl")
    with open(scratch_path, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")

    # Auto-prune: keep last 10 lines
    with open(scratch_path) as f:
        lines = f.readlines()
    if len(lines) > 10:
        with open(scratch_path, "w") as f:
            f.writelines(lines[-10:])
except Exception:
    pass
PY
