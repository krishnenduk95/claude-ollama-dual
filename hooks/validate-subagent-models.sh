#!/bin/bash
# validate-subagent-models: SessionStart hook. Verifies every subagent's
# `model:` frontmatter matches the canonical mapping. If anything has
# drifted, emit a loud warning into additionalContext so the user sees
# it immediately at session start.
#
# Why: today (2026-04-25) we discovered all 9 glm-* subagents had wrong
# `model:` fields pointing at non-GLM models for an unknown period.
# This validator prevents that class of failure recurring silently.

set -eu

AGENTS_DIR="${HOME}/.claude/agents"
[ -d "$AGENTS_DIR" ] || exit 0

python3 <<'PY'
import os
import json
import sys
import re
from pathlib import Path

CANONICAL = {
    "glm-analyst.md":          "glm-5.1:cloud",
    "glm-architect.md":        "glm-5.1:cloud",
    "glm-security-auditor.md": "glm-5.1:cloud",
    "glm-explorer.md":         "kimi-k2.5:cloud",
    "glm-ui-builder.md":       "kimi-k2.5:cloud",
    "glm-reviewer.md":         "deepseek-v4-flash:cloud",
    "glm-worker.md":           "deepseek-v4-flash:cloud",
    "glm-api-designer.md":     "deepseek-v4-flash:cloud",
    "glm-test-generator.md":   "qwen3-coder-next:cloud",
}

agents_dir = Path(os.path.expanduser("~/.claude/agents"))
drifts = []
missing = []

for fname, expected in CANONICAL.items():
    path = agents_dir / fname
    if not path.exists():
        missing.append(fname)
        continue
    # Parse YAML frontmatter (between two --- lines).
    actual = None
    in_frontmatter = False
    with path.open() as f:
        for i, line in enumerate(f):
            if i == 0:
                if line.strip() == "---":
                    in_frontmatter = True
                    continue
                else:
                    break
            if line.strip() == "---":
                break
            m = re.match(r"^model:\s*(\S+)", line)
            if m:
                actual = m.group(1)
                break
    if actual is None:
        drifts.append((fname, expected, "(no model: field)"))
    elif actual != expected:
        drifts.append((fname, expected, actual))

if drifts or missing:
    lines = ["⚠️  SUBAGENT MODEL DRIFT DETECTED"]
    if drifts:
        lines.append("")
        lines.append("The following subagents have a `model:` frontmatter that does NOT match")
        lines.append("the canonical routing table. Dispatches will use the wrong model.")
        lines.append("")
        for fname, expected, actual in drifts:
            lines.append(f"  • {fname}: expected `{expected}`, got `{actual}`")
        lines.append("")
        lines.append("Fix: edit each file's frontmatter and restore the expected model.")
    if missing:
        lines.append("")
        lines.append("Missing subagent files (will fail to dispatch):")
        for fname in missing:
            lines.append(f"  • {fname}")
    msg = "\n".join(lines)
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": msg,
        }
    }))
PY
