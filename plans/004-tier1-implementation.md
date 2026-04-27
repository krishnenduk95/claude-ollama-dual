# Plan 004: Tier 1 + Blind-Spot Fixes — Concrete Implementation

Source: synthesis of glm-analyst chain-of-debate + glm-architect plan-solve-verify
(see plans/003-architectural-upgrades.md for the architecture story).

This plan is the executable to-do list. Each subtask is small, parallelizable
where deps allow, and has a verification step.

## Goal
Implement 9 high-ROI upgrades to claude-dual:
- 5 Tier-1 efficiency wins (small, low-risk)
- 4 blind-spot fixes (security, observability, robustness)
without changing core orchestration model or adding hard external deps.

## Acceptance criteria (per task)

### S1 [glm-worker] Per-model circuit breaker + fallback in proxy
**Files:** `~/.claude-dual/proxy.js`
**Behavior:**
- Add a per-model `failureCounter` map keyed by model id (`deepseek-v4-flash:cloud` etc).
- After 3 consecutive failures on a single model in a 60s window, mark it **degraded** for 5min.
- When a request comes in for a degraded model, log a warning with `event: model_degraded` and respond normally (do NOT auto-substitute — Opus must decide).
- Add `/metrics` exposure: `claude_dual_model_degraded{model="..."} 0|1`.
**Verify:** unit test that simulates 3 failures → 4th request logs degraded; after 5min the counter resets.
**Effort:** ~6h

### S2 [glm-worker] MemPalace relevance gate in fetch-learnings.sh
**Files:** `~/.claude-dual/fetch-learnings.sh`
**Behavior:**
- Compute keyword Jaccard similarity between prompt tokens and each learning entry's tags + what_worked/what_failed text.
- Drop entries with score < 0.15 (current threshold injects everything).
- Cap at top-3 (currently MAX_INJECT=5).
- If zero entries pass threshold, exit silently (no "RELEVANT PAST LEARNINGS" header at all).
- Preserve current keyword stop-list and tokenization.
**Verify:** a generic prompt like "what does this do" → 0 injected. A specific prompt like "stripe webhook idempotency" → top-1-3 entries.
**Effort:** ~4h

### S3 [glm-worker] Hook condition gating
**Files:** `~/.claude/settings.json`, `~/.claude-dual/deep-reason-detector.sh`,
`~/.claude-dual/best-of-n-detector.sh`, `~/.claude-dual/validate-subagent-models.sh`,
`~/.claude-dual/mempalace-auto-mine.sh`
**Behavior:**
- `deep-reason-detector.sh`: skip if prompt < 30 chars (already done — verify) AND if it starts with action verb like "build|fix|create" (already done — verify).
- `validate-subagent-models.sh`: only run when at least one `~/.claude/agents/glm-*.md` file's mtime is newer than the cached check (cache last-check timestamp).
- `mempalace-auto-mine.sh`: skip if `.mempalace/` doesn't exist in cwd (currently runs unconditionally).
- `best-of-n-detector.sh`: silent when no trigger pattern hit (already done — verify it never emits empty injection).
**Verify:** a fresh session with simple prompt fires no UserPromptSubmit injection from these.
**Effort:** ~3h

### S4 [glm-worker] Brief quality PreToolUse hook
**Files:** `~/.claude-dual/brief-quality-gate.sh` (new), `~/.claude/settings.json`
**Behavior:**
- PreToolUse hook with matcher `Agent` (or `Task` per CC version).
- Parses `tool_input.prompt` (the Agent prompt). If it's missing any of:
  - `goal` / "Goal:" pattern
  - `acceptance` / "accept" pattern
  - `verify` / "verification" pattern
  - file list (any path-like token)
- Inject `additionalContext` warning: "Brief quality gate: missing [X, Y]. Consider adding before dispatch — vague briefs produce sloppy output."
- Does NOT block (deny=false).
- Falls back gracefully if `tool_input.prompt` not available in payload.
**Verify:** invoke Agent tool with sparse prompt → warning appears. Invoke with complete brief → silent.
**Effort:** ~4h

### S5 [glm-worker] Per-subagent latency histogram in audit
**Files:** `~/.claude-dual/proxy.js`, `~/.claude-dual/inject-routing-stats.sh`,
`~/.claude-dual/compute-routing-stats.sh`
**Behavior:**
- proxy.js already logs `duration_sec` per request. Add `model_p50_ms`, `model_p95_ms` rolling-window per model in `routing-stats.json`.
- Compute over last 50 requests per model.
- `inject-routing-stats.sh` shows them in the SessionStart banner: `claude-opus-4-7: p50=8.2s p95=14.1s success 100%`.
**Verify:** routing-stats.json after 50+ requests shows p50/p95 fields. SessionStart banner shows them.
**Effort:** ~5h

### B1 [glm-worker] Proxy auth shared-secret enforcement
**Files:** `~/.claude-dual/proxy.js`
**Behavior:**
- proxy already supports `PROXY_AUTH_TOKEN` env (Bearer auth). Check it's actually wired into ALL request paths (not just /v1/messages).
- Add startup warning if proxy listens on non-loopback bind without `PROXY_AUTH_TOKEN`.
- Document `PROXY_AUTH_TOKEN` setup in README — generate, store in launchctl env, set in proxy's launchd plist.
**Verify:** start proxy without auth on 0.0.0.0 → warning logged. Curl with bad token → 401.
**Effort:** ~3h

### B2 [glm-worker] Brief template versioning
**Files:** `~/.claude-dual/brief-templates/v1.json` (new), audit hook in proxy
**Behavior:**
- Define a `BRIEF_TEMPLATE_VERSION` field (default `"v1"`).
- When Opus dispatches via Agent tool, the brief's first line can include `<!-- brief_template: v1 -->`.
- proxy.js audit log gains `brief_template` field if present in request body. If absent, write `null`.
- This is purely instrumentation — doesn't change behavior. Lets us A/B test brief formats later.
**Verify:** audit.jsonl entries gain `brief_template` field on Agent dispatches.
**Effort:** ~3h

### B3 [glm-worker] Ollama outage escalation policy
**Files:** `~/.claude-dual/ollama-outage-policy.md` (new), `~/.claude-dual/proxy.js`
**Behavior:**
- When Ollama circuit is OPEN (currently logs once, then 503s requests):
  - Add a periodic warning log (`event: ollama_outage_active`, every 5min) so user is alerted via tail or notification.
  - On `/health` and `/cost` endpoints, surface "ollama_outage" with start time.
- Document fallback: when Ollama is down, Opus should temporarily skip GLM dispatch and do work directly (raise budget cap awareness in CLAUDE.md).
**Verify:** simulate Ollama down → see periodic logs + `/health` flag.
**Effort:** ~3h

### B4 [glm-worker] Live observability terminal UI
**Files:** `~/.claude-dual/live-stats.sh` (new)
**Behavior:**
- A small bash script that polls `/metrics` + `audit.jsonl` and prints a live dashboard:
  ```
  claude-dual ─ live (refresh 2s)
  Anthropic ▶ closed │ p50 8.2s │ today 36 / 4500 (0.8%) │ today $1.42
  Ollama    ▶ closed │ p50 22s  │ today 23 / 14000 (0.2%)
    deepseek-v4-flash:cloud  closed  p50 22s  ok
    glm-5.1:cloud            closed  p50 36s  ok
    kimi-k2.5:cloud          closed  p50  -   no recent calls
  Last 5 events: ...
  ```
- Refreshes every 2s using `tput cup`.
**Verify:** `~/.claude-dual/live-stats.sh` runs in a terminal and shows live data. Q to quit.
**Effort:** ~5h

## Dependency DAG

```
S2 ─┐
S3 ─┤
S4 ─┼─► (no deps, can run parallel)
S5 ─┤
B1 ─┘

S1 ─► proxy.js change (must serialize with B2, B3 since they touch proxy.js)
B2 ─► proxy.js audit field
B3 ─► proxy.js periodic warning
B4 ─► reads from S5's enriched routing-stats

Parallel batch 1: S2, S3, S4 (different files, no overlap)
Parallel batch 2: S1, B1 (proxy.js — assign to ONE worker as a bundle)
Parallel batch 3: B2, B3 (proxy.js — bundle to ONE worker)
Sequential: S5 → B4
```

## Verification (whole-plan)

After all subtasks merge:
1. `cd ~/.claude-dual && node -e "require('./proxy.js')"` — syntax OK
2. `npm test` in `proxy/` — all unit tests pass
3. Restart proxy via launchctl, hit `/health` — returns 200
4. Run a real subagent dispatch and verify audit.jsonl has new fields
5. Run `~/.claude-dual/live-stats.sh` for 10s — see live data
6. Open a new Claude Code session, simple prompt → verify NO MemPalace injection (irrelevant)
7. Open new session, "stripe webhook" prompt → verify top-1 relevant injection

## Non-goals
- Tier 2 / Tier 3 upgrades (separate plan)
- UI dashboard (just the live-stats.sh terminal UI)
- Multi-model voting (tier 3)
