#!/bin/bash
# plan-drift: SubagentStop hook. When a GLM subagent finishes, look at:
#   1. the plan file(s) referenced in its brief (parse transcript),
#   2. the actual files it changed in the working tree (git diff since dispatch),
# and warn Opus if the agent's file-touch diverges from the plan's "Files to
# touch" / "Create/Edit" section. Pure information — doesn't block.
#
# Hooks in on SubagentStop so the warning fires exactly when Opus is about to
# review the worker's output. Silent when plan file has no file list, or
# when changes match the plan exactly.

set -eu

payload=$(cat)
export HOOK_PAYLOAD="$payload"
export REPO_DIR="$(pwd)"

python3 <<'PY'
import json, os, re, sys, subprocess
from pathlib import Path

DEBUG = os.environ.get("CLAUDE_DEBUG") == "1"
def dbg(msg):
    if DEBUG:
        sys.stderr.write(f"plan-drift[debug]: {msg}\n")

payload = os.environ.get("HOOK_PAYLOAD", "")
try:
    data = json.loads(payload)
except Exception as e:
    dbg(f"payload parse failed: {e!r}")
    sys.exit(0)

# Re-entry guard: if CC has already called this hook in the current stop
# cycle, don't loop. (Some CC versions set stop_hook_active.)
if data.get("stop_hook_active"):
    dbg("skip — stop_hook_active set")
    sys.exit(0)

# SubagentStop payload shape varies across CC versions — try every known field
transcript_path = (
    data.get("transcript_path")
    or data.get("session_transcript_path")
    or data.get("transcript")
    or data.get("transcript_file")
)
subagent_type = (
    data.get("subagent_type")
    or data.get("agent_type")
    or data.get("agent")
    or data.get("sub_agent_type")
    or ""
)
dbg(f"transcript={transcript_path!r} subagent={subagent_type!r}")

# Only meaningful for GLM workers that actually touch code
if not subagent_type.startswith("glm-"):
    # if unknown, still try — SubagentStop doesn't always include type
    if not subagent_type:
        pass
    else:
        sys.exit(0)
if subagent_type in ("glm-explorer", "glm-analyst", "glm-reviewer", "glm-security-auditor"):
    # read-only agents — nothing to drift
    sys.exit(0)

# Extract plan file references from the subagent prompt (if transcript available)
plan_refs = set()
prompt_text = ""
if transcript_path and os.path.exists(transcript_path):
    try:
        with open(transcript_path) as f:
            for line in f:
                try:
                    msg = json.loads(line)
                except Exception:
                    continue
                # message contents vary — walk dict/list recursively for strings
                def walk(o):
                    if isinstance(o, str):
                        yield o
                    elif isinstance(o, dict):
                        for v in o.values(): yield from walk(v)
                    elif isinstance(o, list):
                        for v in o: yield from walk(v)
                for s in walk(msg):
                    for m in re.finditer(r'plans/\d{3}[\w\-]*\.md', s):
                        plan_refs.add(m.group(0))
                    prompt_text += s + "\n"
    except Exception:
        pass

# Also pick up plan refs from the raw payload prompt field (some payload shapes)
for m in re.finditer(r'plans/\d{3}[\w\-]*\.md', json.dumps(data)):
    plan_refs.add(m.group(0))

if not plan_refs:
    sys.exit(0)

repo = os.environ.get("REPO_DIR", ".")
# Pick the most-recently-modified referenced plan file that exists
existing = []
for p in plan_refs:
    full = os.path.join(repo, p)
    if os.path.exists(full):
        existing.append((os.path.getmtime(full), p, full))
if not existing:
    sys.exit(0)
existing.sort(reverse=True)
_, plan_rel, plan_full = existing[0]

# Parse plan's declared files: lines matching file-path patterns under a
# "Files to touch" / "Files" / "Create" / "Edit" / "Scope" heading, OR
# any line with a code-fenced path like `src/foo.ts`.
try:
    plan_text = Path(plan_full).read_text()
except Exception:
    sys.exit(0)

declared = set()
# Block under "## Files" or "### Files to touch" etc
block_re = re.compile(r'(?is)^#+\s*(files?(?:\s+to\s+(?:touch|create|edit))?|scope|deliverables?)\s*\n(.+?)(?=^\s*#|\Z)', re.MULTILINE)
for m in block_re.finditer(plan_text):
    block = m.group(2)
    # backtick-quoted paths and bullet list paths
    for p in re.findall(r'[`"\']([A-Za-z0-9_./\-]+\.[A-Za-z0-9]{1,6})[`"\']', block):
        declared.add(p)
    for p in re.findall(r'^[\s\-\*]+([A-Za-z0-9_./\-]+\.[A-Za-z0-9]{1,6})\b', block, re.MULTILINE):
        declared.add(p)

# Fallback: any backticked file-looking path in the whole doc
if not declared:
    for p in re.findall(r'`([A-Za-z0-9_./\-]+\.[A-Za-z0-9]{1,6})`', plan_text):
        if "/" in p:
            declared.add(p)

if not declared:
    sys.exit(0)

# Bail if not in a git repo — plan-drift only makes sense with version control.
try:
    subprocess.check_output(
        ["git", "-C", repo, "rev-parse", "--git-dir"],
        text=True, stderr=subprocess.DEVNULL, timeout=2
    )
except Exception:
    dbg(f"not a git repo: {repo}")
    sys.exit(0)

# What did git actually change (uncommitted) in the working tree?
try:
    changed = subprocess.check_output(
        ["git", "-C", repo, "status", "--porcelain=v1"],
        text=True, stderr=subprocess.DEVNULL, timeout=3
    )
except Exception as e:
    dbg(f"git status failed: {e!r}")
    sys.exit(0)

actual = set()
for line in changed.splitlines():
    # Format: XY path
    if len(line) < 4: continue
    path = line[3:].strip()
    # Rename: "orig -> new"
    if " -> " in path:
        path = path.split(" -> ")[-1].strip()
    actual.add(path)

if not actual:
    # Worker made no changes — not a drift issue, just empty work. Silent.
    sys.exit(0)

# Normalize: declared paths might be relative. Compare suffix matches.
def matches(decl, a):
    return decl == a or a.endswith("/" + decl) or decl.endswith("/" + a)

unexpected = []
for a in actual:
    if not any(matches(d, a) for d in declared):
        unexpected.append(a)

missing = []
for d in declared:
    if not any(matches(d, a) for a in actual):
        missing.append(d)

if not unexpected and not missing:
    sys.exit(0)

lines = [f"🔍 PLAN DRIFT — subagent output vs. {plan_rel}:"]
if unexpected:
    lines.append(f"  • Unexpected files touched ({len(unexpected)}): " + ", ".join(sorted(unexpected)[:8]))
if missing:
    lines.append(f"  • Declared files NOT touched ({len(missing)}): " + ", ".join(sorted(missing)[:8]))
lines.append("  Review before merging: either the plan was stale, or the worker went out of scope. Update the plan or reject the diff.")

out = {
  "hookSpecificOutput": {
    "hookEventName": "SubagentStop",
    "additionalContext": "\n".join(lines)
  }
}
print(json.dumps(out))
PY
