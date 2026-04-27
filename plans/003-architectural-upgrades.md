# Plan 003: claude-dual Architectural Upgrades

## Goal
Upgrade claude-dual from a static dispatch pipeline to an adaptive, self-correcting orchestration layer with subagent context handoff, automatic failure recovery, outcome-driven routing, brief quality gates, and output validation.

## Non-goals
- Modifying the Claude Code platform itself (streaming, subagent interruption)
- Rewriting the proxy in a different language
- Changing the subagent prompt format (JSON SUMMARY contract stays)
- Adding UI/dashboard for monitoring
- Multi-user support or auth beyond existing Bearer token

## Acceptance criteria
- [ ] Subagent scratch handoff: 2 sequential subagents in a session can see each other's JSON SUMMARY without Opus relay
- [ ] Automatic retry: a subagent returning `status: failure` is retried once on a fallback model, with the failure context injected
- [ ] Brief quality gate: Opus dispatches with missing required fields get a warning injected before the dispatch proceeds
- [ ] Output validation: proxy adds `X-Subagent-Quality` header on GLM responses missing JSON SUMMARY or showing truncation
- [ ] Adaptive routing: routing-stats.json accumulates per-task-type success rates and hints are surfaced at dispatch time
- [ ] All existing hooks and proxy functionality remain unchanged (regression test)

## Architecture decisions

### Decision 1: Subagent context handoff mechanism
Options considered:
  A) Shared JSONL scratch file per session — pros: simple, append-only, no new infra / cons: file I/O on every SubagentStop, needs pruning
  B) Redis/SQLite shared state — pros: queryable, concurrent-safe / cons: new dependency, overkill for 1-user system
  C) Inject prior subagent output into Opus context via SessionStart hook — pros: no new files / cons: context bloat, Opus must relay anyway
Picked: A because it adds zero dependencies, matches the existing JSONL audit pattern, and the SubagentStop hook already fires per subagent completion
Flip if: scratch files grow beyond 500KB per session or concurrent subagent writes cause corruption (switch to SQLite)

### Decision 2: Retry/fallback mechanism
Options considered:
  A) SubagentStop hook with automatic re-dispatch — pros: immediate recovery, no Opus involvement / cons: complex, needs to invoke Agent tool which only Opus can do
  B) Proxy-level retry with model substitution — pros: transparent, works at HTTP level / cons: proxy can't modify the subagent's prompt context
  C) SubagentStop hook that injects a "retry needed" signal into Opus's context — pros: Opus retains control, simpler / cons: adds one Opus turn
Picked: C because Claude Code's architecture only allows the main session (Opus) to dispatch subagents; hooks can't invoke the Agent tool. The hook injects a retry signal, Opus sees it and re-dispatches with the failure context. One extra turn but preserves the control model.
Flip if: Claude Code adds support for programmatic subagent dispatch from hooks (then switch to A)

### Decision 3: Routing stats schema for task-type granularity
Options considered:
  A) Extend existing routing-stats.json with agents.{agent}.{task_type} nested structure — pros: backward compatible, minimal change / cons: schema gets deep
  B) Separate per-agent JSONL files with task_type tags — pros: append-only, streamable / cons: more files to manage
  C) Add task_type to audit.jsonl entries, let compute-routing-stats aggregate — pros: single source of truth, no schema change / cons: requires parsing audit entries for task_type
Picked: C because audit.jsonl already exists as the source of truth and compute-routing-stats.sh already parses it; just need to extract task_type from the JSON SUMMARY embedded in Ollama response bodies (or from the scratch file)
Flip if: audit.jsonl grows too large for 200ms parsing (then switch to B)

### Decision 4: Brief quality gate implementation
Options considered:
  A) PreToolUse hook on Agent tool — pros: intercepts before dispatch, matches delegation-enforcer pattern / cons: Agent tool payload may not contain the full prompt in the hook input
  B) UserPromptSubmit hook that detects "dispatch" patterns — pros: sees full prompt / cons: too early, before Opus has written the brief
  C) PreToolUse hook on Write that checks for plan files — pros: catches vague plans / cons: misses direct Agent dispatches without plans
Picked: A with defensive parsing — if the Agent tool payload doesn't include the full prompt, fall back to a warning that lists the required fields. Even partial coverage is better than none.
Flip if: Claude Code starts providing full Agent tool input to PreToolUse hooks (then full enforcement becomes possible)

### Decision 5: Output validation scope
Options considered:
  A) Full response parsing and semantic quality scoring — pros: catches content issues / cons: expensive, high false positive rate, LLM-in-the-loop
  B) Structural validation only (JSON SUMMARY presence, truncation detection, repetition detection) — pros: fast, low false positive rate, deterministic / cons: misses semantic quality issues
  C) No validation (status quo) — pros: zero risk / cons: quality escapes
Picked: B because structural validation is deterministic, fast (<1ms on typical responses), and has a clear rollback path. Semantic validation is a v2 concern.
Flip if: false positive rate exceeds 5% on production traffic (then relax truncation detection)

## Component diagram

```
User Prompt
    │
    ▼
[UserPromptSubmit hooks]
    ├── deep-reason-detector.sh (existing)
    ├── best-of-n-detector.sh (existing)
    ├── fetch-learnings.sh (existing + MODIFIED: also inject scratch entries)
    └── adaptive-routing-hint.sh (NEW)
    │
    ▼
Opus 4.7 (main session)
    │ dispatches GLM subagents via Agent tool
    ▼
[PreToolUse hooks]
    ├── delegation-enforcer.sh (existing, Read/Edit/Write/Grep/Glob)
    └── brief-quality-gate.sh (NEW, Agent tool)
    │
    ▼
[proxy.js] ──► Anthropic / Ollama
    │                               │
    │   (NEW: validateSubagentOutput) │
    │   adds X-Subagent-Quality header │
    │                               │
    ▼                               ▼
GLM subagent completes
    │
    ▼
[SubagentStop hooks]
    ├── plan-drift.sh (existing)
    ├── subagent-handoff.sh (NEW: writes JSON SUMMARY to scratch)
    └── subagent-quality-gate.sh (NEW: checks status, injects retry signal)
    │
    ▼
~/.claude-dual/scratch/{session_id}.jsonl  (NEW)
    │
    ▼
Next subagent dispatch → fetch-learnings.sh injects scratch context
```

## Subtasks (dependency DAG)

### 001 [glm-worker] Brief quality gate hook
- Inputs: `~/.claude/settings.json` (hook structure), `~/.claude-dual/delegation-enforcer.sh` (pattern reference)
- Outputs: `~/.claude-dual/brief-quality-gate.sh`, updated `~/.claude/settings.json` (add PreToolUse hook for Agent)
- Acceptance: hook fires on Agent tool calls; injects warning if prompt is missing any of [goal, acceptance criteria, verification]; does not block; exits cleanly on non-Agent tools
- Estimated effort: 4h

### 002 [glm-worker] Subagent scratch handoff
- Inputs: `~/.claude/settings.json`, `~/.claude-dual/fetch-learnings.sh` (to modify)
- Outputs: `~/.claude-dual/subagent-handoff.sh`, `~/.claude-dual/scratch/` (directory), modified `~/.claude-dual/fetch-learnings.sh`
- Acceptance: SubagentStop hook appends JSON SUMMARY to scratch/{session_id}.jsonl; fetch-learnings.sh injects recent scratch entries as additionalContext; scratch file pruned to last 10 entries; defensive JSON parsing with fallback
- Estimated effort: 6h

### 003 [glm-worker] Proxy output validation
- Inputs: `~/.claude-dual/proxy.js` (response handling lines 800-898)
- Outputs: Modified `~/.claude-dual/proxy.js` with `validateSubagentOutput()` function
- Acceptance: GLM responses missing JSON SUMMARY get `X-Subagent-Quality: missing-summary` header; truncated responses get `X-Subagent-Quality: possibly-truncated`; valid responses get no extra header; all existing proxy tests pass
- Estimated effort: 8h

### 004 [glm-worker] depends: 002 — Subagent quality gate with retry signal
- Inputs: `~/.claude/settings.json`, `~/.claude-dual/fallback-chains.json` (new), `~/.claude-dual/subagent-handoff.sh`
- Outputs: `~/.claude-dual/subagent-quality-gate.sh`, `~/.claude-dual/fallback-chains.json`, updated `~/.claude/settings.json`
- Acceptance: On SubagentStop, if JSON SUMMARY status=failure, injects additionalContext with retry signal including fallback model; does not auto-retry (Opus decides); respects max 1 retry signal per original dispatch
- Estimated effort: 10h

### 005 [glm-worker] depends: 004, 003 — Adaptive routing with task-type accumulation
- Inputs: `~/.claude-dual/compute-routing-stats.sh`, `~/.claude-dual/routing-stats.json`, `~/.claude-dual/audit.jsonl`
- Outputs: Modified `~/.claude-dual/compute-routing-stats.sh` (task_type extraction), new `~/.claude-dual/adaptive-routing-hint.sh`, updated `routing-stats.json` schema
- Acceptance: routing-stats.json includes per-agent per-task-type success rates when n >= 5; adaptive-routing-hint.sh injects routing hints on UserPromptSubmit when dispatch is imminent; falls back to static mapping when data is insufficient
- Estimated effort: 15h

## Risks + mitigations
- **Risk:** Agent tool payload not available to PreToolUse hooks
  **Mitigation:** brief-quality-gate.sh falls back to a reminder message listing required fields; partial coverage is still better than none
- **Risk:** Scratch file grows unbounded in long sessions
  **Mitigation:** Auto-prune to last 10 entries per session; sessions are ephemeral (cleared on SessionStart)
- **Risk:** Fallback model also fails, creating double latency
  **Mitigation:** Hard cap of 1 automatic retry signal; second failure escalates to Opus with full context
- **Risk:** Output validation false positives on legitimate non-JSON responses
  **Mitigation:** Only validate responses from Ollama models (check `provider === 'ollama'`); only check last 2KB for JSON SUMMARY
- **Risk:** routing-stats.json has cold-start problem (no per-task-type data)
  **Mitigation:** Fall back to static CANONICAL mapping when n < 5; adaptive hints are additive, never override explicit model selection

## Out of scope (future work)
- Streaming/early-termination of subagent output (requires Claude Code platform changes)
- Semantic quality scoring of subagent responses (LLM-in-the-loop, high cost)
- Dashboard/UI for monitoring dispatch patterns
- Multi-user auth or session isolation beyond current scratch directory