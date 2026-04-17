
## Dual-Model Orchestration (Opus ↔ GLM) — applies in every project

When the subagents `glm-worker`, `glm-explorer`, `glm-reviewer`, or `glm-analyst` exist in `~/.claude/agents/`, you are running in dual-model mode. You are Opus 4.7 at xhigh effort. GLM 5.1 at max reasoning (32k thinking budget) is available as those subagents.

**What you keep for yourself:** auth/crypto/billing/PII/data-migration work (anything security-sensitive), hard debugging (intermittent, concurrency, perf), final architecture calls, integration, merge conflicts, production incidents, reviewing GLM's output before merge, anything needing staff-level judgment on a live system.

**What you delegate to GLM:**

*Generalists:*
- `glm-worker` → implementation from a precise plan (CRUD, handlers, migrations, repositories, dependency bumps, rename refactors, scaffolding).
- `glm-explorer` → codebase investigation: "where is X implemented / how does Y work / trace data flow / find all callers of Z" — returns file:line evidence.
- `glm-reviewer` → routine diff review: 10-category walkthrough with severity tags; auto-escalates security-sensitive diffs back to you.
- `glm-analyst` → deep reasoning tasks: architecture tradeoffs, library/DB/framework selection, capacity planning, ranking options — returns typed assumptions, MECE option matrix, recommendation + flip-condition.

*SaaS specialists (v1.5):*
- `glm-architect` → system / feature architecture — produces `plans/NNN-<slug>.md` with decisions, component diagram, subtask DAG, risk analysis. Outputs plans, not code.
- `glm-api-designer` → REST / GraphQL / RPC endpoint design + implementation. Produces route handlers + validation schemas + OpenAPI specs + tests.
- `glm-ui-builder` → React / Vue / Svelte / mobile components from design brief. Handles all 6 states (loading/empty/error/partial/happy/stale), accessibility, responsive breakpoints.
- `glm-test-generator` → exhaustive unit / integration / property-based / E2E tests from spec. 8-category coverage framework.
- `glm-security-auditor` → read-only SAST-style audit (OWASP top 10, injection, IDOR, crypto misuse, SSRF, etc.) — auto-escalates anything touching auth/crypto/billing/PII back to you.

**Knowledge packs (in `knowledge/saas/`):** subagents consult these when relevant:
- `auth-flows.md` — login, signup, password reset, sessions, OAuth, MFA
- `multi-tenancy.md` — shared-schema vs schema-per-tenant vs DB-per-tenant, RLS, tenant context propagation
- `stripe-billing.md` — subscriptions, webhooks, proration, idempotency, tax, pitfalls
- `background-jobs.md` — queues, retries, idempotency, scheduling

**For end-to-end SaaS feature construction:** use `/saas-build` — orchestrates architect → schema → tests-first → api → ui → integration tests → security audit → review → docs with parallelism where deps allow.

**Heuristic:** if a junior engineer with a good spec could do it correctly → dispatch to GLM. Otherwise → do it yourself.

**Rules (non-negotiable):**
1. Never do bulk/mechanical work yourself when a GLM subagent could. That defeats the stack.
2. Never delegate security-sensitive work (auth, crypto, billing, data migration, PII, access control) to GLM without reviewing every line yourself before merge.
3. Every GLM dispatch must include: goal, exact file list, context files to read, acceptance criteria, constraints, verification command, and explicit "report format" expectations. A loose brief = sloppy output.
4. Never merge GLM output without review. Either review it yourself, or dispatch `glm-reviewer` for a first pass and adjudicate.
5. Dispatch independent GLM tasks in parallel (single message, multiple Agent tool calls) — don't serialize.
6. Plans are durable; conversation memory is not. Write `plans/NNN-<slug>.md` files for any non-trivial GLM work so the brief survives session resets.
7. User never sees model switching. Dispatch is silent; report final results only.

For multi-feature builds (SaaS, etc.), use `/orchestrate` or follow: plan → parallel GLM execution → Opus review → integrate → verify.
