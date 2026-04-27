# Plan 005: Tier 2 — Adaptive Orchestration (execution)

Source: plans/003-architectural-upgrades.md (architect's design).
Reconciliation: Tier 1 already implemented brief-quality-gate.sh (subtask 001 in plan 003). Skip it here.

This plan covers the 4 remaining Tier 2 architectural upgrades:

| # | Subtask | Owner | Effort | Depends |
|---|---|---|---|---|
| T2-A | Subagent scratch handoff | glm-worker | M | — |
| T2-B | Proxy output validation (X-Subagent-Quality header) | glm-worker | M | — |
| T2-C | Subagent quality gate with retry signal | glm-worker | M | T2-A |
| T2-D | Adaptive routing with task-type accumulation | glm-worker | L | T2-A, T2-B |

**Parallel batches:**
- Batch 1: T2-A + T2-B (independent files)
- Batch 2: T2-C (depends on T2-A's scratch file)
- Batch 3: T2-D (depends on T2-A scratch + T2-B audit metadata)

## T2-A — Subagent scratch handoff

**Goal:** When a GLM subagent finishes, append its JSON SUMMARY to a per-session scratch file. The next subagent's dispatch sees recent scratch entries injected as context, so subagents can build on each other without Opus rewriting briefs.

**Files:**
- CREATE `~/.claude-dual/subagent-handoff.sh` — SubagentStop hook
- CREATE `~/.claude-dual/scratch/` — directory (handoff hook creates it on first use)
- EDIT `~/.claude-dual/fetch-learnings.sh` — append a "RECENT SUBAGENT OUTPUT" section pulling top-N scratch entries
- EDIT `~/.claude/settings.json` — register subagent-handoff.sh under SubagentStop

**Behavior:**
1. SubagentStop fires. Hook reads stdin payload — extracts `session_id`, `subagent_type`, `transcript_path`.
2. From transcript, extract the last JSON SUMMARY block (look for the canonical `{"subagent": ..., "task_type": ..., "status": ...}` shape in the last 2KB).
3. Append one JSONL line to `~/.claude-dual/scratch/{session_id}.jsonl`:
   ```json
   {"ts":"2026-04-26T...","subagent":"glm-worker","task_type":"...","status":"success","key_finding":"...","files_touched":[...]}
   ```
4. Auto-prune to last 10 entries per session file (rewrite if length > 10).
5. fetch-learnings.sh: at the END (after learnings injection), append a "RECENT SUBAGENT OUTPUT (this session)" section with last 3 scratch entries from current session if scratch file exists. Bounded to 500 chars total to avoid context bloat.

**Acceptance criteria:**
- SubagentStop fires → scratch file gains 1 line.
- 11+ subagent stops → file pruned to last 10.
- Next user prompt in same session → fetch-learnings.sh injects "RECENT SUBAGENT OUTPUT" section with up to 3 recent scratch entries.
- Different session → different scratch file, no cross-pollution.
- Defensive: missing transcript or malformed JSON → silent exit 0.

## T2-B — Proxy output validation

**Goal:** Proxy detects structurally-bad GLM responses (missing JSON SUMMARY, truncation) and stamps a quality header. Opus reads the header on review and adjudicates.

**Files:**
- EDIT `~/.claude-dual/proxy.js` — add `validateSubagentOutput()` called after Ollama response body is buffered

**Behavior:**
1. Only validate responses where `provider === 'ollama'` and the response body is non-empty JSON.
2. Extract the message text (Anthropic-shaped: `content[].text`; Ollama-native: `message.content`).
3. Check structural quality:
   - **missing-summary**: last 2KB of message text doesn't contain a JSON object with the keys `subagent`, `status` (case-insensitive). Note: subagents end with a JSON SUMMARY block per CLAUDE.md.
   - **possibly-truncated**: response ends mid-word, mid-JSON, mid-code-fence, or mid-sentence (no terminal punctuation). Heuristics: last char is `,` or `{` or `[`, OR no `.!?}` in the last 50 chars.
   - **healthy**: passes both checks → no header.
4. Stamp on response: `X-Subagent-Quality: missing-summary | possibly-truncated | healthy`.
5. ALSO write the quality flag to audit log on `request_end`: `subagent_quality: "missing-summary"` (or null if healthy/anthropic).
6. Do NOT modify the body. Header is metadata only.

**Acceptance criteria:**
- Curl Ollama through proxy with prompt that produces JSON SUMMARY → header present, value `healthy` (or absent — pick one and stick with it).
- Curl with prompt forced to truncate (low max_tokens) → header `possibly-truncated`.
- Anthropic responses → no header (don't touch them).
- All existing proxy tests still pass.
- Audit log entries for ollama responses gain `subagent_quality` field.

## T2-C — Subagent quality gate with retry signal

**Goal:** When a subagent returns `status: failure`, inject a retry-signal into Opus's next turn so Opus can re-dispatch with the failure context (using a fallback model).

**Files:**
- CREATE `~/.claude-dual/subagent-quality-gate.sh` — SubagentStop hook
- CREATE `~/.claude-dual/fallback-chains.json` — model → fallback mapping
- EDIT `~/.claude/settings.json` — register subagent-quality-gate.sh under SubagentStop (after subagent-handoff.sh)

**Behavior:**
1. SubagentStop fires. Read stdin payload, find session_id + subagent_type + transcript_path.
2. Read transcript, extract last JSON SUMMARY.
3. If `status === "failure"`:
   - Read fallback-chains.json to find next model in chain (e.g. `glm-worker` falls back to `glm-architect`, or to a different Ollama model).
   - Track retry count per session: `~/.claude-dual/scratch/{session_id}.retry-count.json` — increment for this dispatch's `key_finding` hash. If >= 1, do NOT inject another retry signal (cap at 1 auto-retry per failure).
   - Inject SubagentStop additionalContext:
     ```
     ⚠ SUBAGENT FAILURE — {subagent_type} reported status=failure: "{key_finding}"
     Suggested fallback: re-dispatch as {fallback_subagent} with the failure context as part of the new brief.
     This is your decision — Opus retains control. Skip if the failure is acceptable or if context loss outweighs retry value.
     ```
4. If status is success or unknown → exit 0 silent.
5. Defensive: missing transcript/parse error → exit 0 silent.

**fallback-chains.json shape:**
```json
{
  "glm-worker": ["glm-api-designer", "glm-architect"],
  "glm-explorer": ["glm-architect"],
  "glm-reviewer": ["glm-security-auditor"],
  "glm-analyst": ["glm-architect"],
  "glm-architect": [],
  "glm-api-designer": ["glm-worker"],
  "glm-ui-builder": ["glm-worker"],
  "glm-test-generator": ["glm-worker"],
  "glm-security-auditor": []
}
```

**Acceptance criteria:**
- Subagent returns `status: failure` → SubagentStop injection contains "SUBAGENT FAILURE" + fallback name.
- Subagent returns `status: success` → silent.
- Same failure twice in a session → second time silent (cap honored).
- Fallback chain empty for an agent (e.g. glm-architect) → message says "no fallback available, escalate to Opus directly".

## T2-D — Adaptive routing with task-type accumulation

**Goal:** Track per-agent + per-task-type success rates over time. When Opus is about to dispatch, surface a hint: "for task_type=X, glm-worker succeeded 90% (n=12), glm-api-designer succeeded 70% (n=8) — pick glm-worker."

**Files:**
- EDIT `~/.claude-dual/proxy.js` — when stamping audit `request_end` for ollama, also pull `task_type` from response body's JSON SUMMARY (if present). Add `task_type` field to audit entry.
- EDIT `~/.claude-dual/compute-routing-stats.sh` — aggregate per-agent + per-task-type success rates from audit.jsonl. Emit into `routing-stats.json.agents.{agent}.task_types.{task_type} = {n, success_rate, avg_latency}`.
- CREATE `~/.claude-dual/adaptive-routing-hint.sh` — UserPromptSubmit hook. Detects "dispatch X" / "use Y subagent" patterns or simply runs every turn. Reads routing-stats. If user prompt mentions a task type or known keywords, inject the hint.
- EDIT `~/.claude/settings.json` — register adaptive-routing-hint.sh under UserPromptSubmit.

**Behavior:**
1. **Audit enrichment:** when proxy completes an Ollama request, peek at the response body's last 2KB for a JSON SUMMARY. If found, parse and grab `task_type`. Stamp into audit entry.
2. **Aggregation:** compute-routing-stats.sh extends its current per-model stats with per-agent + per-task-type:
   ```json
   {
     "agents": {
       "glm-worker": {
         "task_types": {
           "small-bash-edit": {"n": 7, "success_rate": 1.0, "avg_latency_sec": 18.2},
           "proxy-circuit-breaker-and-auth": {"n": 1, "success_rate": 1.0}
         }
       }
     }
   }
   ```
3. **Hint injection:** adaptive-routing-hint.sh — UserPromptSubmit hook:
   - Skip if quota is at warning/exhausted (don't add noise).
   - Read prompt. Look for keywords: "dispatch", "delegate", "implement", "refactor", "explore", "review", "audit", "design", "test", "ui", "build".
   - If a keyword maps to a known task_type (use a small map), look up routing-stats.json `agents.{agent}.task_types.{task_type}` for all known agents.
   - Filter to entries with n >= 5 (cold-start guard).
   - If 2+ agents have stats for this task_type, inject:
     ```
     📊 ROUTING HINT (last 30d): for {task_type}-shaped tasks:
       - glm-worker: 90% success (n=12), avg 18s
       - glm-api-designer: 70% success (n=8), avg 22s
     Suggestion: prefer glm-worker. Override if you need {agent}'s specific capabilities.
     ```
   - If only 1 agent has data → no hint (not enough comparison).
   - If no keyword match → silent.

**Acceptance criteria:**
- audit.jsonl entries for ollama gain `task_type` field when response had a JSON SUMMARY.
- routing-stats.json gains `agents.{agent}.task_types.{type}` aggregations.
- UserPromptSubmit with "implement X" or "refactor Y" → hint shown if 2+ agents have data.
- UserPromptSubmit with "hello" → no hint.
- compute-routing-stats backwards compatible with old audit entries (missing task_type → skip).

## Verification (whole-plan)

After all 4 subtasks merge:
1. `node --check ~/.claude-dual/proxy.js` — passes.
2. `cd proxy && npm test` — all 33 tests pass.
3. Restart proxy via launchctl. `/health` returns 200.
4. Trigger a GLM dispatch (e.g. "explore the proxy codebase briefly") → after completion:
   - scratch/{session_id}.jsonl has 1 line
   - audit.jsonl request_end has `subagent_quality` and `task_type` fields
5. Trigger a SECOND dispatch with the same session → scratch grows to 2 lines, fetch-learnings.sh injection includes "RECENT SUBAGENT OUTPUT" section.
6. Force a failure (impossible task) → SubagentStop injection includes "SUBAGENT FAILURE".
7. Wait for compute-routing-stats cron → routing-stats.json gains task_type aggregations.
8. New session: `echo "implement X"` prompt → adaptive-routing-hint surfaces routing hint (if data available).

## Rollback

Each subtask isolated:
- T2-A: remove subagent-handoff.sh + revert fetch-learnings.sh + delete scratch/.
- T2-B: revert proxy.js validation function (single function, easy diff).
- T2-C: remove subagent-quality-gate.sh + delete fallback-chains.json.
- T2-D: revert compute-routing-stats.sh + remove adaptive-routing-hint.sh + ignore task_type in audit (forward-compatible).

## Non-goals
- Auto-dispatching the retry (T2-C only signals; Opus decides)
- Semantic quality (T2-B is structural only)
- Dynamic re-routing during a dispatch (T2-D is hint-only at user-prompt time)
- Multi-session scratch sharing (per-session isolation)
