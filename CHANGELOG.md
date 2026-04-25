# Changelog

All notable changes to this project will be documented here.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and (from v1.0.0 onward) uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **MemPalace integration (memory fabric, auto-indexed per project).** Installed `mempalace` (3.3.3, MIT, Python) at user scope and registered its MCP server globally so its 29 memory tools are available in every Claude Code session. Three hooks wire up automation, mirroring the existing `code-review-graph` pattern: `mempalace-auto-mine.sh` (SessionStart) detects whether `cwd` has `mempalace.yaml` or `.git`, then runs `mempalace init --yes` + `mempalace mine` in a backgrounded subshell — first session in any new project triggers indexing without blocking startup; `mempalace-save.sh` (Stop) and `mempalace-precompact.sh` (PreCompact) capture conversation transcripts so cross-session recall works for free. Refuses to mine `$HOME` or `/`. Lock-file guards prevent concurrent mines for the same project. Logs to `~/.claude-dual/mempalace-auto-mine.log`. Storage at `~/.mempalace/` (palace) plus per-project `mempalace.yaml`/`entities.json` (already in `.gitignore` post-init).
- **Subagent role-based model specialization.** All 9 `glm-*` subagents previously routed to `glm-5.1:cloud` regardless of task shape. They now route to the model whose strengths match the role: `glm-worker` / `glm-reviewer` / `glm-api-designer` → `deepseek-v4-flash:cloud` (LiveCodeBench 91.6, fast structured code); `glm-explorer` / `glm-ui-builder` → `kimi-k2.5:cloud` (fastest at ~22s, visual-to-code specialty); `glm-test-generator` → `qwen3-coder-next:cloud` (coding-specialist breadth). The 3 deepest-reasoning roles — `glm-architect`, `glm-analyst`, `glm-security-auditor` — stay on `glm-5.1:cloud` because GLM-5.1's 8-hour autonomous task capability and SWE-Bench Pro #1 OSS ranking are unmatched for long-horizon planning, tradeoff analysis, and adversarial audits.
- **`validate-subagent-models.sh` SessionStart hook.** Verifies every `glm-*` subagent's frontmatter `model:` field matches the canonical role-to-model mapping. Emits a loud `⚠️  SUBAGENT MODEL DRIFT DETECTED` warning into session context if any agent has drifted. Prevents recurrence of the silent misrouting found on 2026-04-25, when all 9 agents had wrong `model:` fields for an unknown period.
- **Mandatory JSON summary block on every subagent.** Every `glm-*` subagent now ends its report with a single fenced JSON block `{subagent, task_type, status, files_touched, tests_run, tests_pass, key_finding, blockers, next_action}`. The prose narrative remains for human review; the JSON is the canonical machine-readable contract Opus parses to decide its next move without re-reading the full diff. Reduces orchestrator token consumption.
- **Audit log rotation + integrity (v1.20.0).** `~/.claude-dual/rotate-audit-log.sh` rotates `audit.jsonl` daily into `audit-archive/audit-YYYY-MM-DD.jsonl(.gz)` with a SHA-256 sidecar per archive. 30-day retention. Runs via a dedicated LaunchAgent (`com.luciffer.claude-dual-rotate-audit.plist`) at 03:17 local + once on load. The proxy's write fd survives rotation (we truncate in-place rather than `mv`-then-recreate), so no proxy restart is required.
- **Proxy integration test suite (`proxy/test-integration.js`).** Fixture-driven regression tests covering all four bug categories shipped this week — TTL ordering in-section (B1), TTL ordering cross-section (B2), 4-breakpoint cap (B3), Ollama `max_tokens` ceiling (B4). 12 assertions over 6 fixtures. Wired into `npm test` alongside the unit suite.

### Removed

- **Proxy v1.19.0 — smart-routing.** v1.16.0 added a downgrade path that rewrote tiny Opus requests to Sonnet or Haiku based on input-character thresholds. Across 30 days of real traffic the path fired **zero times** because Claude Code's default `thinking=enabled` is correctly excluded by the guard, and almost all requests carry that flag. The feature was dead code in the hot path of every Anthropic request and contributed to two of the four proxy bugs shipped earlier this week. Removed entirely (function, CFG keys, all 5 unit tests). Net effect on observed behavior: none.

### Fixed

- **Proxy v1.18.0 — clamp `max_tokens` to per-model output ceiling when routing to Ollama.** Claude Code's subagent harness routinely sends `max_tokens=128000`, which works for Claude models but exceeds the output cap on several Ollama cloud models. Production error today: `max_tokens (128000) exceeds model's maximum output tokens (65536) for model deepseek-v3.2` — every GLM subagent dispatch to that model failed at the API boundary. Fix: `applyGlmRigor` now consults a per-model `MODEL_MAX_OUTPUT` table (deepseek-v3.2:cloud=65536, glm-5.1:cloud=98304, kimi-k2.5:cloud=131072, qwen3-coder-next:cloud=65536, cogito-2.1:671b-cloud=65536) and clamps `max_tokens` down to the model's ceiling. Unknown models fall back to a safe `SAFE_MAX_OUTPUT_FALLBACK=60000`. When clamping reduces `max_tokens` below the caller's `thinking.budget_tokens`, the thinking budget is shrunk too so at least 1024 output tokens of headroom remain. Clamping only reduces — never raises the caller's request. Six new unit tests cover all clamp paths.
- **Proxy v1.17.3 — respect Anthropic's 4-breakpoint hard cap.** The v1.17.x injector was adding up to 4 `cache_control` breakpoints of its own without counting breakpoints the upstream client (Claude Code) had already placed in the payload. Total could reach 6+, triggering HTTP 400 (`A maximum of 4 blocks with cache_control may be provided. Found 6.`). The injector now counts existing breakpoints first (`_countExistingBreakpoints`) and only fills the remaining budget, so the total never exceeds 4. Also fixes a pre-existing bug where the breakpoint counter incremented even when the target block already had a `cache_control`, causing later section injection to short-circuit unnecessarily. Two regression tests cover the budget-exhausted and budget-partial cases.
- **Proxy v1.17.2 — prompt cache TTL ordering is GLOBAL, not per-section.** v1.17.1 only checked for existing `1h` breakpoints within the section it was about to touch. But Anthropic processes `cache_control` blocks in a single flattened sequence across the whole request (`tools` → `system` → `messages`), and *every* `ttl='1h'` block must come before *every* `ttl='5m'` block in that sequence. So if Claude Code places a `1h` breakpoint anywhere in `system` or `messages` and our proxy stamps a default `5m` on `tools[last]`, the request is rejected even though each section looks self-consistent. The injector now scans the entire payload once up-front and, if any `1h` breakpoint exists anywhere, promotes every breakpoint it adds to `1h` so the global ordering invariant holds. Two new cross-section regression tests cover this.
- **Proxy v1.17.1 — prompt cache TTL ordering (same-section).** When an upstream client pre-marked an earlier block in a section with `cache_control.ttl='1h'`, the v1.17.0 auto-injector stamped a default `5m` breakpoint on a later block in the same section, which Anthropic rejects with HTTP 400. The injector now detects existing TTLs in-section and matches `1h` when present. (Superseded but still in effect via the broader v1.17.2 global scan.)

### Planned

- Docker image + compose file for containerized deployment
- Grafana dashboard + Prometheus alert rules
- Bedrock/Vertex failover providers
- Web dashboard for routing stats + cost tracking
- `glm-schema-designer`, `glm-docs-writer`, `glm-adversary` subagents
- Knowledge packs for: deployment/infra, email (transactional), real-time (websockets), observability

## [1.5.0] - 2026-04-17 — SaaS Builder

The system can now build a SaaS end-to-end — architecture → schema → tests-first → APIs → UI → integration tests → security audit → review — with GLM specialists handling each layer at Opus 4.7-tier quality.

### Added

**Five new SaaS specialist subagents (v1.5, in addition to the four generalists):**

- `glm-architect` — system/feature architect. Produces structured `plans/NNN-<slug>.md` with goal, non-goals, architecture decisions (each with flip-condition), component diagram, subtask DAG (dependencies + owners + acceptance criteria + effort estimates), risks. Outputs plans, not code.
- `glm-api-designer` — REST/GraphQL/RPC endpoint designer. Produces route handlers + Zod/Joi/Pydantic validation schemas + OpenAPI entries + full test suites (happy/400/401/403/404/409/429). Hunts for IDOR, mass assignment, timing oracles, SSRF, CSRF, open redirects.
- `glm-ui-builder` — React/Vue/Svelte/mobile component builder. Enforces the 6-state rule (loading/empty/error/partial/happy/stale), WCAG accessibility, responsive breakpoints (360/768/1024/1440), and matches existing CSS system. No default `any` types, no inline styles when the codebase has a system.
- `glm-test-generator` — exhaustive test generator. 8-category coverage framework (happy, boundaries, type edges, concurrency, external failures, idempotency, security, auth). Supports unit, integration, property-based (fast-check / Hypothesis).
- `glm-security-auditor` — read-only SAST specialist. Walks 12 categories (injection, auth, authz/IDOR, secrets, crypto, deserialization, SSRF, open redirect, XSS, security headers, rate limiting, log leakage). Auto-escalates CRITICAL findings and anything touching auth/crypto/billing/PII back to Opus for personal review.

**Four SaaS knowledge packs (referenced by subagents when relevant):**

- `knowledge/saas/auth-flows.md` — login, signup, password reset, sessions, JWT, OAuth, MFA, passkeys. Covers bcrypt/argon2, session fixation, password reset rules, common mistakes.
- `knowledge/saas/multi-tenancy.md` — shared-schema vs schema-per-tenant vs DB-per-tenant decision matrix, Postgres RLS implementation, tenant context propagation, common IDOR pitfalls, migration from single-tenant.
- `knowledge/saas/stripe-billing.md` — subscription data model, webhook handling with idempotency, proration, tax, feature gating, "don't build this" list.
- `knowledge/saas/background-jobs.md` — queue selection (Redis/Postgres/SQS), idempotency, retry strategies, dead-letter queues, observability, anti-patterns.

**New `/saas-build` orchestration command:**

End-to-end SaaS feature build pipeline that runs:
1. Phase 0 — scope clarification (Opus asks ≤5 questions, batched)
2. Phase 1 — architecture (`glm-architect` produces plan file)
3. Phase 2 — schema + data layer (parallel workers)
4. Phase 3 — **tests FIRST** (TDD — failing tests before implementation)
5. Phase 4 — API layer (`glm-api-designer` parallel dispatch)
6. Phase 5 — UI layer (`glm-ui-builder` parallel dispatch)
7. Phase 6 — integration / E2E tests
8. Phase 7 — security audit (`glm-security-auditor`, CRITICAL findings escalate to Opus)
9. Phase 8 — final review (`glm-reviewer` across 10 categories)
10. Phase 9 — docs update (`glm-worker` for README/CHANGELOG/API docs)
11. Phase 10 — Opus integration + verification

**Updated delegation rules in global CLAUDE.md** — 9 subagents now listed with routing guidance; `/saas-build` referenced for end-to-end construction.

### Changed

- Total subagent count: 4 → 9
- Lines of domain knowledge shipped with the system: 0 → ~780 (across 4 knowledge packs)
- Global delegation rule expanded to cover specialist routing

### Honest capability note

GLM 5.1 per-task quality is unchanged by this release — the model is fixed. What changed is the **system's** end-to-end output quality. By combining:

- Specialist subagents (each with narrower, deeper framework)
- Test-driven dispatch (tests written before implementation = working implementation)
- Security audit pass (catches what review misses)
- Knowledge grounding (subagents consult proven patterns)
- Parallel dispatch (multiple workers running concurrently per phase)

...the full pipeline produces output that can meet or exceed what single-model Opus 4.7 would produce on an ambitious SaaS build — because no single model run covers every category the way a specialist pipeline does.

## [1.0.0] - 2026-04-17

First tagged release. The stack went from "working personal tool" to "production-grade open-source project" in this release.

### Added

**Core proxy (v2)**
- Health endpoints: `/health`, `/livez`, `/readyz`, `/metrics` (Prometheus), `/cost`
- Structured JSON logging via pino with per-request IDs for trace correlation
- Prometheus metrics: request counters, duration histograms, circuit state gauges, retry counter, rate-limit-rejected counter, in-flight gauge, cost-per-model gauge
- Retry with exponential backoff + jitter on 5xx and network failures (default 3 attempts)
- Per-provider circuit breaker: opens after 5 consecutive failures, half-opens after 30s, auto-closes on success
- Per-provider token-bucket rate limiting (default 200 req/min, configurable)
- Request body size limit (default 10 MB, configurable) with 413 rejection
- Optional Bearer token auth (`PROXY_AUTH_TOKEN` env), preserves Claude Max OAuth passthrough
- Graceful shutdown on SIGTERM/SIGINT: stops accepting, drains in-flight (30s timeout)
- Cost tracking per model per day with 80% and 100% budget alerts
- Audit trail (JSON lines) of every dispatch at `~/.claude-dual/audit.jsonl`
- 12+ configuration knobs via environment variables (all with sensible defaults)

**Cross-platform support**
- Linux systemd user unit at `service/linux/claude-dual-proxy.service`
- Windows service installer `service/windows/install-service.ps1` (NSSM preferred, Task Scheduler fallback)
- Windows service uninstaller `service/windows/uninstall-service.ps1`
- `install.sh` detects macOS/Linux and uses the appropriate service manager
- `install.ps1` for Windows-native installation
- `uninstall.sh` for clean removal on macOS and Linux

**Testing + CI**
- Unit test suite at `proxy/test/proxy.test.js` using Node 18+ built-in `node:test`
- GitHub Actions CI on Ubuntu + macOS across Node 18/20/22
- shellcheck on install/uninstall scripts
- systemd unit validation
- plist validation

**Open-source hygiene**
- `SECURITY.md` with private disclosure policy
- `CONTRIBUTING.md` with setup, PR process, and scope
- `CHANGELOG.md` (this file)
- Issue templates: bug report, feature request, config
- Pull request template with checklist

**GLM subagent upgrades**
- All four subagents (`glm-worker`, `glm-explorer`, `glm-reviewer`, `glm-analyst`) updated with Opus 4.7-tier rigor frameworks
- `glm-worker`: 7 explicit 4.7-style discipline patterns (pre-flight API verification, hallucination guard, long-horizon coherence, iterate-on-errors, complexity escalation, design-smell detection, subtle-bug awareness)
- `glm-reviewer`: 10 review categories including new Design quality; 12-point subtle-bug hunt checklist
- `glm-explorer`: design-signal detection while investigating
- `glm-analyst`: 2nd-order consequences dimension, quantified reversibility

**Honest capability documentation**
- README now includes a "GLM 5.1 vs Opus 4.7 — honest capability notes" section with SWE-bench benchmarks and sourced comparisons
- Clarified that `xhigh` effort is a Claude-only tier (GLM uses `max reasoning (32k thinking budget)` in Anthropic format)

### Changed

- Upgraded main model from Claude Opus 4.6 (max effort) to Claude Opus 4.7 (xhigh effort)
- Proxy now has a `package.json` with pinned deps (pino 9.5.0, prom-client 15.1.3) and a `node >=18` engine
- Proxy rewritten from 140 lines to ~590 lines with enterprise-grade architecture, but preserves backward compatibility — existing sessions continue to work unchanged

### Security

- Proxy auth via `PROXY_AUTH_TOKEN` env with timing-safe comparison
- Claude Max OAuth (`Bearer sk-ant-*`) always passes through auth check (designed behavior, OAuth is the auth)
- Request body size limit prevents OOM from malformed oversized payloads

## [0.1.0] - 2026-04-15

Initial release:
- macOS-only LaunchAgent-based proxy
- Basic Opus/GLM routing
- Four GLM subagents (v1 prompts)
- `/orchestrate` slash command
- Setup docs

[Unreleased]: https://github.com/krishnenduk95/claude-ollama-dual/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/krishnenduk95/claude-ollama-dual/releases/tag/v1.0.0
[0.1.0]: https://github.com/krishnenduk95/claude-ollama-dual/commit/ecdb9f6
