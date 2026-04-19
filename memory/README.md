# Learnings fabric

This directory stores the shared postmortem corpus for the claude-dual stack (v1.8.0+).

At runtime it lives at `~/.claude-dual/memory/learnings.jsonl` — an append-only JSONL file where each line is one task postmortem written by a GLM subagent at task exit.

## Schema

```json
{
  "ts": "2026-04-19T14:32:10Z",
  "agent": "glm-worker",
  "task_type": "stripe-webhook-handler",
  "approach": "",
  "outcome": "success|failure|partial",
  "what_worked": "string, <=500 chars",
  "what_failed": "string, <=500 chars",
  "verified": false,
  "tags": ["stripe", "webhook", "idempotency"]
}
```

## How it's used

1. **Write path** (subagent at task exit):
   ```bash
   ~/.claude-dual/write-learning.sh "glm-worker" "<task-type>" "<outcome>" "<worked>" "<failed>" "tag1,tag2"
   ```

2. **Read path** (UserPromptSubmit hook on every prompt):
   `~/.claude-dual/fetch-learnings.sh` — scores every past entry by keyword overlap with the incoming prompt, weights by exponential time-decay (30-day half-life) and a verified-flag bonus, injects the top 5 as `hookSpecificOutput.additionalContext`. Opus sees prior verdicts before acting.

## Rotation

The write script rotates the file to `learnings.YYYYMMDD.jsonl` when it exceeds 10MB. Rotated files are kept for manual inspection; only the active file is consulted by the fetch hook.

## Seeding

On fresh install, seed with one bootstrap entry so the fetch hook has something to skip past:

```bash
~/.claude-dual/write-learning.sh "bootstrap" "init" "success" "fabric initialized" "" "init"
```
