# Changelog

All notable changes to this project will be documented here.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and (from v1.0.0 onward) uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- **Proxy v1.17.1 — prompt cache TTL ordering.** When an upstream client (e.g. Claude Code) pre-marked an earlier block with `cache_control.ttl='1h'`, the v1.17.0 auto-injector stamped a default `'5m'` breakpoint on a later block in the same section, which Anthropic rejects with HTTP 400 (`ttl='1h' cache_control block must not come after a ttl='5m' cache_control block`). The injector now detects existing TTLs per section (tools / system / messages) and, when a `1h` breakpoint is already present, promotes its own additions to `1h` so the ordering constraint is preserved. Regression tests added in `proxy/test-v15-v17.js`.

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
