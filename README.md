# claude-dual — Claude Opus 4.7 + GLM 5.1 in one Claude Code session

**One command, two frontier models, zero manual switching.** `claude-dual` wires Claude Opus 4.7 (via your Claude Max subscription) and GLM 5.1 Cloud (via Ollama) into a single Claude Code session so Opus orchestrates and GLM executes — automatically, across any project folder.

![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-blue)
![Node](https://img.shields.io/badge/node-%E2%89%A518-green)
![Claude%20Code](https://img.shields.io/badge/Claude%20Code-2.x-orange)
![GLM](https://img.shields.io/badge/GLM-5.1%20Cloud-purple)
![Agents](https://img.shields.io/badge/subagents-9-blueviolet)
![Tests](https://img.shields.io/badge/tests-27%20passing-brightgreen)
![CI](https://github.com/krishnenduk95/claude-ollama-dual/actions/workflows/ci.yml/badge.svg)
![Version](https://img.shields.io/badge/version-1.5.0-informational)

> Built for developers who ran into Anthropic's tightened Claude Max usage caps and want to stretch every Opus token without losing reasoning quality.

---

## Table of contents

- [What this does](#what-this-does)
- [Why it exists](#why-it-exists)
- [Prerequisites](#prerequisites)
- [Install](#install)
- [Usage](#usage)
- [How delegation works](#how-delegation-works)
- [Architecture](#architecture)
- [Typical Opus ↔ GLM split](#typical-opus--glm-split)
- [Real-world scenarios](#real-world-scenarios)
- [Verification & testing](#verification--testing)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Design decisions](#design-decisions)
- [Support this project](#support-this-project)
- [Credits](#credits)

---

## What this does

- Keeps your main Claude Code session on **Opus 4.7 at xhigh effort** (your Claude Max subscription — no API key needed).
- Registers four GLM 5.1–backed subagents (`glm-worker`, `glm-explorer`, `glm-reviewer`, `glm-analyst`) that Opus dispatches automatically based on task shape.
- Routes every request through a production-grade proxy that forwards Anthropic's OAuth bearer token intact (so Claude Max keeps working) while sending GLM requests to Ollama.
- Injects **extended thinking (32k tokens)** + **temperature 0.3** on GLM calls so GLM output approaches Opus-tier reasoning on code and routine analysis.
- Works in **any directory, any project** — the delegation rule lives in your global `~/.claude/CLAUDE.md`.
- **Runs on macOS, Linux, and Windows** with native service management (LaunchAgent / systemd user unit / NSSM or Task Scheduler).

**You type normally. Opus and GLM coordinate under the hood. You never touch `/model`.**

## Enterprise-grade proxy (v1.0.0)

The proxy isn't just a router — it's a hardened HTTP gateway with:

| Capability | How |
|---|---|
| **Health + readiness** | `GET /health`, `/livez`, `/readyz` for monitoring tools |
| **Prometheus metrics** | `GET /metrics` — request counters, duration histograms, circuit state, cost, in-flight gauges |
| **Cost tracking + alerts** | `GET /cost` with per-model breakdown; warns at 80% and errors at 100% of `COST_DAILY_LIMIT_USD` |
| **Audit trail** | Every dispatch logged as JSON lines at `~/.claude-dual/audit.jsonl` |
| **Structured logging** | pino-based JSON logs with per-request IDs for trace correlation |
| **Retry with backoff** | 3 attempts with exponential backoff + jitter on network errors and 5xx |
| **Circuit breaker** | Per-provider; opens after 5 failures, half-opens after 30s, auto-closes on success |
| **Rate limiting** | Token bucket, 200 req/min per provider (tunable via `RATE_LIMIT_RPM`) |
| **Request size limit** | 10 MB default (`MAX_REQUEST_BYTES`), rejects oversized with 413 |
| **Optional auth** | Set `PROXY_AUTH_TOKEN` to require Bearer auth; Claude Max OAuth always passes through |
| **Graceful shutdown** | SIGTERM drains in-flight requests, exits within 30s |
| **Unit tested** | 27 passing tests via `node:test`, CI on macOS + Ubuntu × Node 18/20/22 |

All 12+ knobs tunable via env vars. See `proxy/proxy.js` header for full list.

## SaaS Builder pipeline (v1.5)

Beyond the 4 generalist subagents (worker/explorer/reviewer/analyst), v1.5 adds 5 specialists for end-to-end SaaS construction:

| Specialist | What it does |
|---|---|
| `glm-architect` | System/feature architecture — produces `plans/NNN-<slug>.md` with decisions + dependency DAG |
| `glm-api-designer` | REST/GraphQL endpoints + validation schemas + OpenAPI + full test suites |
| `glm-ui-builder` | React/Vue/Svelte components — enforces 6-state rule (loading/empty/error/partial/happy/stale), a11y, responsive |
| `glm-test-generator` | Exhaustive tests from spec — 8-category coverage (boundaries, concurrency, security, idempotency, etc.) |
| `glm-security-auditor` | Read-only SAST across 12 categories (OWASP top 10 + more); auto-escalates CRITICAL to Opus |

Plus **4 knowledge packs** (`knowledge/saas/`) that specialists consult when relevant:

- `auth-flows.md` — login, signup, reset, sessions, JWT, OAuth, MFA, passkeys
- `multi-tenancy.md` — shared-schema / schema-per-tenant / DB-per-tenant + Postgres RLS
- `stripe-billing.md` — subscriptions, webhooks, proration, idempotency, tax
- `background-jobs.md` — queues, retries, idempotency, dead-letters

### The `/saas-build` pipeline

For end-to-end feature construction, use `/saas-build`:

```
/saas-build Build a tenant invitation feature: admins invite by email, invitees accept via token, email notification, multi-use vs single-use toggle, expires in 7 days.
```

Runs automatically:

```
Phase 0  (Opus) scope clarification (≤5 questions if needed)
Phase 1  (glm-architect) architecture + plan file
Phase 2  (parallel workers) schema + migrations + models
Phase 3  (glm-test-generator) tests FIRST — TDD
Phase 4  (glm-api-designer × N parallel) API handlers + validation + OpenAPI
Phase 5  (glm-ui-builder × N parallel) UI components with 6-state coverage
Phase 6  (glm-test-generator) integration + E2E tests
Phase 7  (glm-security-auditor) 12-category SAST pass
Phase 8  (glm-reviewer) 10-category diff review
Phase 9  (glm-worker) docs + CHANGELOG
Phase 10 (Opus) integration + verification
```

Specialists dispatch in parallel within a phase where deps allow. Opus orchestrates and reviews every handoff. Security findings touching auth/crypto/billing/PII **always** escalate back to Opus.

This doesn't make GLM 5.1 equal to Opus 4.7 on every raw task — it makes the **system's** end-to-end output match or exceed what a single Opus pass would produce, because no single model run covers every specialist dimension the way the pipeline does.

---

## Why it exists

Anthropic reduced Claude Max usage limits. Running every task on Opus burns the quota fast. GLM 5.1 Cloud is cheap, near-Opus-4.6 on SWE-bench Verified and ahead of 4.6 on SWE-bench Pro, and speaks the Anthropic message format natively through Ollama — so it's a natural worker model if you can route requests correctly.

**The hard part:** Claude Max authenticates with OAuth, not an API key. Every off-the-shelf router (claude-code-router, LiteLLM, ollama-launch) substitutes the Authorization header with a configured API key, which breaks Claude Max. This project's ~100-line custom proxy forwards the incoming Authorization header untouched on Anthropic routes — keeping OAuth alive — while handling GLM routes normally.

The rest is orchestration discipline: four subagents with Opus-grade rigor frameworks built into their system prompts, a global CLAUDE.md delegation rule, a LaunchAgent to keep the proxy alive, and a launcher that ties it all together.

---

## Prerequisites

Install these **before** running the installer:

| Requirement | Why | Install |
|---|---|---|
| **macOS** | LaunchAgent used for persistent proxy (Linux needs a systemd unit instead — adaptable) | built-in |
| **Node.js ≥ 18** | Runs the proxy | `brew install node` or [nodejs.org](https://nodejs.org) |
| **Ollama** | Serves the `glm-5.1:cloud` model | [ollama.com](https://ollama.com) — download the app |
| **Claude Code CLI (≥ 2.0)** | The CLI we're orchestrating | [docs.claude.com/en/docs/claude-code](https://docs.claude.com/en/docs/claude-code) — `npm install -g @anthropic-ai/claude-code` |
| **Active Claude.ai Max subscription** | Opus 4.7 access | Sign in: `claude login` |
| **Ollama Cloud signin (free)** | Pulls cloud-hosted GLM 5.1 | `ollama signin` |
| **`glm-5.1:cloud` pulled** | The model we route GLM requests to | `ollama pull glm-5.1:cloud` *(installer does this for you if missing)* |

Verify everything is in place:

```bash
node --version            # v18+ expected
ollama --version          # any recent version
claude --version          # 2.0+ expected
ollama list               # should show glm-5.1:cloud (or installer will pull it)
claude -p "Hi" --model claude-opus-4-7   # confirms your Claude Max signin works
```

---

## Install

### One-shot installer (recommended)

```bash
git clone https://github.com/krishnenduk95/claude-ollama-dual.git
cd claude-ollama-dual
chmod +x install.sh
./install.sh
```

The installer will:

1. Verify prerequisites (Node, Ollama, Claude Code).
2. Pull `glm-5.1:cloud` if you don't have it.
3. Copy the four subagent definitions to `~/.claude/agents/`.
4. Copy the `/orchestrate` slash command to `~/.claude/commands/`.
5. Install the proxy at `~/.claude-dual/proxy.js`.
6. Install the launcher at `~/.local/bin/claude-dual` (chmod +x).
7. Generate and load the LaunchAgent at `~/Library/LaunchAgents/com.claude-dual-proxy.plist` (auto-start on login, auto-restart on crash).
8. Append the global delegation rule to `~/.claude/CLAUDE.md`.
9. Set `effortLevel: "xhigh"` in `~/.claude/settings.json`.
10. Verify the proxy is listening on port 3456.

If `~/.local/bin` isn't on your `PATH`, add this to your `~/.zshrc` or `~/.bash_profile`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Reopen your terminal. You should now be able to run `claude-dual` from anywhere.

### Manual install (if you prefer control)

```bash
# 1. Create target dirs
mkdir -p ~/.claude-dual ~/.claude/agents ~/.claude/commands ~/.local/bin ~/Library/LaunchAgents

# 2. Copy files from the cloned repo
cp proxy/proxy.js                      ~/.claude-dual/proxy.js
cp agents/*.md                         ~/.claude/agents/
cp commands/orchestrate.md             ~/.claude/commands/
cp bin/claude-dual                     ~/.local/bin/claude-dual
chmod +x ~/.local/bin/claude-dual

# 3. LaunchAgent (for persistent proxy)
sed "s|__HOME__|$HOME|g" launchagent/com.claude-dual-proxy.plist.template \
  > ~/Library/LaunchAgents/com.claude-dual-proxy.plist
launchctl load -w ~/Library/LaunchAgents/com.claude-dual-proxy.plist

# 4. Delegation rule into your global CLAUDE.md
cat claude-md/dual-model-orchestration.md >> ~/.claude/CLAUDE.md

# 5. xhigh effort as default (requires jq — brew install jq)
jq '. + {"effortLevel":"xhigh","alwaysThinkingEnabled":true}' ~/.claude/settings.json > /tmp/s.json \
  && mv /tmp/s.json ~/.claude/settings.json

# 6. Verify
lsof -iTCP:3456 -sTCP:LISTEN   # should show node listening
claude-dual -p "Reply: OK" --model claude-opus-4-7
```

### First run

```bash
cd ~/any-project-you-want
claude-dual
```

Inside the session, talk to Opus normally. For a quick smoke test:

```
Dispatch glm-worker to create hello.py with a greet(name) function and one pytest test. Read it back and confirm.
```

You'll see Opus plan, GLM execute, Opus review — all in one command, one session.

---

## Usage

### Daily workflow

```bash
# From any project folder:
claude-dual
```

Then talk to Opus. Examples:

```
# Build a feature end-to-end
Build a tenant-invitation feature: schema, POST /invites endpoint, accept UI, email, tests.

# Codebase audit
Audit this codebase for security, perf, dead code, and test gaps. Use glm-explorer subagents in parallel. Give me a prioritized fix list.

# Targeted change
In src/checkout/payment.ts, change retry logic from fixed 3-attempt exponential backoff to jittered backoff capped at 30s. Keep the public API identical.

# Analyze + fix
My /api/dashboard endpoint has 800ms p95 latency. Analyze why, recommend a fix, then implement it.

# Architecture decision
Should we move our analytics pipeline from nightly Python-on-Batch to DuckDB or Spark? Cost + migration tradeoffs, please.
```

### Slash command

```
/orchestrate Build a multi-tenant billing module with Stripe, webhooks, invoice PDFs, and audit logs.
```

Forces the full plan → parallel GLM execution → Opus review → integration flow.

### Forcing a specific subagent

Usually Opus picks correctly. When you want to override:

```
Use glm-explorer to find how authentication is wired in this codebase.
Use glm-analyst to compare Postgres vs DuckDB for our analytics pipeline.
Use glm-reviewer to walk the diff against main for anything risky.
Use glm-worker to implement plans/002-auth.md.
```

### Watching routing live

```bash
tail -f ~/.claude-dual/proxy.log
```

Each request line shows the provider, model, and (for GLM) the rigor injection parameters.

---

## How delegation works

When you type a prompt in a `claude-dual` session, Opus classifies the task using the delegation rules in your global `~/.claude/CLAUDE.md`:

| Task shape | Handler |
|---|---|
| Architecture, auth/crypto/billing/PII, hard debugging (concurrency, intermittent, perf), final review, merge conflicts, production incidents | **Opus (keeps)** |
| Implementation from a plan — CRUD, handlers, migrations, tests, UI components, dep bumps, rename refactors, scaffolding | `glm-worker` |
| Codebase investigation — "where is X / how does Y work / trace data flow / find callers of Z" | `glm-explorer` |
| Routine diff / PR review across 9 categories with severity tags (auto-escalates security-sensitive diffs to Opus) | `glm-reviewer` |
| Architecture tradeoff analysis, library/DB/framework selection, capacity planning, ranking options | `glm-analyst` |

**Each subagent carries an Opus-grade rigor framework in its system prompt:**

- `glm-worker`: 6-dimension pre-flight thinking (decompose → assumptions → tradeoffs → edge cases → invariants → failure modes) → execute → mandatory self-review → verification with captured test output.
- `glm-explorer`: hypothesis-driven search; every claim cites `file:line` or is flagged as inference.
- `glm-reviewer`: 9-category walkthrough (correctness / plan conformance / edge cases / tests / style / perf / security / scope / backwards-compat) with BLOCKER / ISSUE / NIT / QUESTION severity tags.
- `glm-analyst`: 5-phase framework (frame → typed assumptions `[given]`/`[derived]`/`[my-guess]` → MECE options → dimension-matrix analysis → recommendation with flip-condition and load-bearing assumptions named).

**The proxy additionally injects on every GLM call:**

- `thinking.budget_tokens: 32000` (extended reasoning — verified to lift GLM's thinking from ~5.9k chars baseline to ~18.8k chars on complex tasks)
- `temperature: 0.3` (consistent reasoning)
- `max_tokens` floor of 8192 (headroom for thinking + output)
- `max_tokens` **ceiling clamp per model** (v1.18.0): `deepseek-v3.2:cloud → 65536`, `glm-5.1:cloud → 98304`, `kimi-k2.5:cloud → 131072`, `qwen3-coder-next:cloud → 65536`, `cogito-2.1:671b-cloud → 65536`. Unknown models fall back to `60000`. Clamping only reduces — never raises — and shrinks `thinking.budget_tokens` if needed to keep ≥1024 output tokens of headroom.

---

## Which model runs when

Everything in one table so you can see exactly which model handles each role, what endpoint it hits, and when the proxy rewrites the model on the fly.

| Role / trigger | Model | Endpoint | When it runs |
|---|---|---|---|
| **Main Claude Code session** (orchestrator you talk to) | `claude-opus-4-7` | `api.anthropic.com` via OAuth | Every user turn — Opus is the orchestrator and final reviewer |
| `glm-worker` subagent (implementation from plan) | `deepseek-v4-flash:cloud` | `localhost:11434/v1/messages` (Ollama → cloud) | `subagent_type=glm-worker` — flash's coding scores (LiveCodeBench 91.6) + 30s latency suit mechanical execution |
| `glm-reviewer` subagent (diff / PR review) | `deepseek-v4-flash:cloud` | Ollama | `subagent_type=glm-reviewer` — fast code understanding for routine review |
| `glm-api-designer` subagent | `deepseek-v4-flash:cloud` | Ollama | `subagent_type=glm-api-designer` — strict structured-code generation |
| `glm-explorer` subagent (code investigation) | `kimi-k2.5:cloud` | Ollama | `subagent_type=glm-explorer` — fastest model on the rack (~22s) for read-only retrieval |
| `glm-ui-builder` subagent | `kimi-k2.5:cloud` | Ollama | `subagent_type=glm-ui-builder` — visual-to-code is kimi's specialty |
| `glm-test-generator` subagent | `qwen3-coder-next:cloud` | Ollama | `subagent_type=glm-test-generator` — coding-specialist breadth across edge cases |
| `glm-architect` subagent (SaaS plans) | `glm-5.1:cloud` | Ollama | `subagent_type=glm-architect` — long-horizon planning, GLM 5.1's 8-hour autonomous task strength |
| `glm-analyst` subagent (tradeoff analysis) | `glm-5.1:cloud` | Ollama | `subagent_type=glm-analyst` — deep reasoning, SWE-Bench Pro #1 OSS |
| `glm-security-auditor` subagent | `glm-5.1:cloud` | Ollama | `subagent_type=glm-security-auditor` — CyberGym 68.7 adversarial; depth > speed for audits |

> **Subagents are routed to specialized cloud models by role.** The 6 fast/coding-heavy subagents use `deepseek-v4-flash`, `kimi-k2.5`, or `qwen3-coder-next`. The 3 deepest-reasoning roles (architect, analyst, security-auditor) stay on `glm-5.1:cloud`. A SessionStart hook (`validate-subagent-models.sh`) verifies this routing on every session start and warns loudly if any subagent's frontmatter has drifted from the canonical mapping. The proxy's per-model `max_tokens` clamp (v1.18.0) keeps each model within its output ceiling.

**Routing rules the proxy applies automatically:**

1. **Pass-through by model name.** Anything matching `^claude-` goes to `api.anthropic.com` with your OAuth Bearer token forwarded untouched. Anything matching `^(glm-\|gemma\|qwen\|llama\|mistral\|phi\|deepseek\|kimi\|cogito)` or containing `:` goes to Ollama.
2. **GLM rigor injection** (extended thinking, temperature, max_tokens floor + per-model ceiling clamp — see above).
3. **Context compression** (v1.15.0) dedupes old Read tool results and stubs stale large tool outputs before forwarding to Anthropic — reduces input tokens without touching recent turns.
4. **Prompt cache breakpoints** (v1.17.x) are injected on stable prefixes (system prompt, tool defs, a mid-history message, a tail message), capped at 4 total across the whole request, with TTLs that preserve Anthropic's global `1h before 5m` ordering rule. The injector counts existing breakpoints from the upstream client first and only fills the remaining budget.
5. ~~**Smart routing**~~ removed in v1.19.0 — fired 0 times across 30 days of real traffic because Claude Code defaults `thinking=enabled`. The dead path is gone.

**What you see on your side:** one `claude-dual` command. You never pick the model. Opus decides what to dispatch, the proxy decides what to rewrite.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  $ claude-dual                                              │
└─────────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  claude-dual launcher  (~/.local/bin/claude-dual)           │
│    - ensures proxy is running (LaunchAgent or fallback)     │
│    - sets ANTHROPIC_BASE_URL=http://127.0.0.1:3456          │
│    - unsets ANTHROPIC_API_KEY (so OAuth wins)               │
│    - execs `claude`                                         │
└─────────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Claude Code process                                         │
│    Main model: Opus 4.7 (Claude Max OAuth)                  │
│    Subagents: glm-worker / glm-explorer / glm-reviewer /    │
│               glm-analyst   (frontmatter model=glm-5.1:cloud)│
└─────────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Proxy   (~/.claude-dual/proxy.js, port 3456)               │
│                                                              │
│   model = claude-*            model = glm-* / *:*           │
│        │                           │                         │
│        ▼                           ▼                         │
│   api.anthropic.com          localhost:11434/v1/messages    │
│   (OAuth Bearer token        (Ollama → GLM 5.1 Cloud;        │
│    forwarded untouched)       proxy injects thinking=32k,    │
│                               temp=0.3, max_tokens≥8192)     │
└─────────────────────────────────────────────────────────────┘
```

---

## GLM 5.1 vs Opus 4.7 — honest capability notes

GLM 5.1 is a strong open-weights model from Z.ai (Mixture-of-Experts, 754B total / 40B active parameters). It's excellent for delegated worker tasks but is **not equivalent** to Opus 4.7 on every dimension. Here's the honest read so you know what to expect:

| Benchmark | GLM 5.1 | Opus 4.6 | Opus 4.7 | Read |
|---|---:|---:|---:|---|
| SWE-bench Verified | 77.8% | 80.8% | 87.6% | Opus 4.7 pulled significantly ahead (~10 pt gap). |
| SWE-bench Pro (harder, real GitHub issues) | **58.4** | 57.3 | n/a public | GLM 5.1 beats Opus 4.6; Opus 4.7 figure not public yet. |
| AIME 2026 I (math) | 92.7% | n/a | n/a | GLM 5.1 is strong at competition math. |
| GPQA-Diamond (graduate-level reasoning) | 86.0% | n/a | n/a | Competitive with top frontier models. |
| Internal Claude-Code harness coding eval (Z.ai self-reported) | 45.3 (94.6% of Opus 4.6) | 47.9 | n/a | Claim not yet independently replicated. |

**What this means in practice:**

- **GLM 5.1 is very good for what we delegate to it** — CRUD implementation, refactors, codebase exploration, routine review, scaffolding, test-writing from a spec. The 32k thinking budget + temperature 0.3 injection + our rigor-framework system prompts close most of the remaining gap against Opus on these tasks.
- **Opus 4.7 is still meaningfully stronger on hard reasoning** — novel architecture, subtle concurrency bugs, security-sensitive work, production incident diagnosis. The delegation rule in `~/.claude/CLAUDE.md` keeps exactly those tasks on Opus and ships the bulk-volume work to GLM. That's the whole point of the split.
- **If you push GLM beyond its sweet spot, you'll feel it.** If you find GLM's output landing at 80–90% of what you'd expect from Opus on a task, that's accurate — and it's why Opus reviews every GLM dispatch before the result reaches you.

**Sources:** SWE-bench ([vals.ai](https://www.vals.ai/benchmarks/swebench)), [Z.ai GLM 5.1 benchmarks](https://huggingface.co/zai-org/GLM-5.1), [Opus 4.7 launch](https://www.anthropic.com/news/claude-opus-4-7), [independent comparison](https://wavespeed.ai/blog/posts/glm-5-1-vs-claude-gpt-gemini-deepseek-llm-comparison/).

---

## Typical Opus ↔ GLM split

| Scenario | Opus | GLM |
|---|---:|---:|
| Greenfield feature build | 20% | 80% |
| Implementing from a plan | 15% | 85% |
| Refactor / dep bump / migration | 10% | 90% |
| Codebase audit (parallel explorers) | 15% | 85% |
| Architecture / DB choice | 40% | 60% |
| "Analyze and fix" (2-phase) | 30% | 70% |
| Routine PR / diff review | 30% | 70% |
| Hard debugging (intermittent, concurrency) | 70% | 30% |
| Security / auth / billing work | 95% | 5% |
| Production incident | 90% | 10% |

**Default expectation for typical SaaS work: ~30% Opus / ~70% GLM by token volume.**

---

## Real-world scenarios

### "Audit my whole codebase"

Opus splits the audit into security / perf / dead code / test gaps / a11y dimensions, dispatches `glm-explorer` subagents in parallel, synthesizes their findings into a prioritized report. Never reads every file itself.

### "Change this portion from here"

Opus reads the portion + 2–3 neighbor files for style, writes a precise brief, dispatches `glm-worker`. GLM edits, runs tests, reports. Opus reviews the diff and signs off.

### "Analyze this thing properly, then fix it"

Two-phase. Opus dispatches `glm-analyst` (or `glm-explorer` if codebase-local) to produce a structured analysis with typed assumptions and a recommendation. Opus reviews, converts the analysis into a plan, dispatches `glm-worker` to execute.

### "Build me a new feature from scratch"

Opus writes `plans/001-schema.md`, `002-api.md`, `003-ui.md`, `004-tests.md`, then dispatches `glm-worker` subagents in parallel (one per plan). Opus handles cross-file integration glue. Runs the full test suite before reporting done.

### "Debug this intermittent bug"

**Opus-heavy.** Opus reasons through hypotheses; `glm-explorer` fetches targeted code evidence; Opus narrows the cause; `glm-worker` adds instrumentation and the fix; Opus verifies under a repro.

### "Migrate from library X to Y"

Opus writes a master migration plan, dispatches many `glm-worker` subagents in parallel (one per module), handles tricky type-system or config work itself, uses `glm-reviewer` to walk each chunk before merge.

---

## Verification & testing

### Quick health check

```bash
lsof -iTCP:3456 -sTCP:LISTEN                          # proxy listening
launchctl list | grep claude-dual                     # LaunchAgent loaded
curl -sf http://localhost:11434/api/tags | head       # Ollama reachable
ollama list | grep glm-5.1                            # model present
claude-dual -p "Reply: OK" --model claude-opus-4-7    # Opus round-trip
```

### Test GLM directly (shows thinking tokens)

```bash
curl -s -X POST http://127.0.0.1:3456/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: test" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"glm-5.1:cloud","max_tokens":2000,"messages":[{"role":"user","content":"Reply: OK"}]}' \
  | python3 -m json.tool | head -30
```

You should see `"type": "thinking"` blocks in the `content` array and the model metadata `"model": "glm-5.1"`.

### End-to-end orchestration test

```bash
claude-dual -p --permission-mode bypassPermissions --model claude-opus-4-7 \
  "Dispatch glm-worker to create hello.py with a greet(name) function and one pytest test. Then read it back and confirm."
```

While it runs, `tail -f ~/.claude-dual/proxy.log` in another terminal — you'll see Opus → Ollama (4–5 calls for GLM's agentic loop) → Opus again.

The `examples/` directory (if present after testing) contains reference request/response bodies from a complete run.

---

## Troubleshooting

### Opus isn't responding / 401 from Anthropic

Your Claude Max OAuth token expired. Run `claude` directly (not `claude-dual`); if it prompts you to sign in, do so. Then `claude-dual` works again.

### GLM returns `model not found`

The model name in Ollama doesn't match what the subagents request. Check:

```bash
ollama list
```

If it shows `glm-4.6:cloud` or similar instead of `glm-5.1:cloud`, update the `model:` field in each `~/.claude/agents/glm-*.md`.

### Proxy not running

```bash
launchctl list | grep claude-dual        # if missing:
launchctl load -w ~/Library/LaunchAgents/com.claude-dual-proxy.plist
# Or as an immediate fallback:
nohup node ~/.claude-dual/proxy.js > ~/.claude-dual/proxy.log 2>&1 &
```

### Wrong routing in the log

Every proxy log line has `→ ANTHROPIC` or `→ OLLAMA` with the model name. If `model=` is empty or unknown prefix, it defaults to Anthropic. Check your subagent frontmatter `model:` field if GLM requests are going to Anthropic.

### Subagents not being dispatched

```bash
ls ~/.claude/agents/glm-*.md
grep "Dual-Model Orchestration" ~/.claude/CLAUDE.md
```

Both must be present. The installer does this; if you installed manually, double-check.

### `ollama list` shows no models loaded in memory

That's expected for cloud-served models. `glm-5.1:cloud` is served remotely through Ollama's cloud; it doesn't need to be loaded into local VRAM. First call has ~5s warmup latency.

---

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.claude-dual-proxy.plist
rm ~/Library/LaunchAgents/com.claude-dual-proxy.plist
rm -rf ~/.claude-dual
rm ~/.local/bin/claude-dual
rm ~/.claude/agents/glm-{worker,explorer,reviewer,analyst}.md
rm ~/.claude/commands/orchestrate.md
# Manually remove the "Dual-Model Orchestration (Opus ↔ GLM)" section from ~/.claude/CLAUDE.md
# Manually revert effortLevel in ~/.claude/settings.json if you want
```

---

## Design decisions

**Why a custom proxy instead of claude-code-router / LiteLLM?**
Every off-the-shelf router substitutes the Authorization header with a configured API key per provider. Claude Max uses OAuth — there's no API key to paste. The custom proxy forwards the incoming Authorization header untouched on `claude-*` routes, which is the behavior no off-the-shelf tool offers today.

**Why Ollama over direct Z.ai / Anthropic-compat cloud?**
User preference during build. Ollama also happens to be convenient: it speaks Anthropic format natively at `/v1/messages`, so the proxy doesn't need to translate request/response bodies. Swap to Z.ai or another Anthropic-compat endpoint by editing the `OLLAMA_HOST`/`OLLAMA_PORT` constants in `proxy/proxy.js`.

**Why inject thinking budget in the proxy rather than per-call?**
Claude Code makes many implicit calls (summarization, background tasks). Injecting centrally ensures every GLM call benefits from extended thinking and consistent reasoning — no per-call configuration.

**Why four subagents instead of one generic `glm-agent`?**
Claude Code dispatches based on the `description` field in subagent frontmatter. Four narrow descriptions (implementation / investigation / review / analysis) let Opus pick the right tool for the task shape, and each system prompt enforces a framework tuned to that shape.

**Why temperature 0.3 for GLM?**
Lower temperature on a high-reasoning model produces more careful, deterministic answers — closer to what Opus does with its default. When Claude Code's Agent tool overrides with `temperature: 1` on subagent dispatches, the 32k thinking budget still carries the rigor, so output quality stays high.

---

## Support this project

### Your 1 Cent Can Change Thousand Lives

Building, debugging, and maintaining open-source tooling like this takes real hours — OAuth-preserving proxies, rigor frameworks, end-to-end testing, writing the docs you're reading right now. If `claude-dual` saved you time, token quota, or money, please consider sending a small donation. Every contribution — no matter how small — keeps us motivated to build and share the next tool that benefits thousands of developers.

**Donate:** [rzp.io/rzp/l5Oit61a](https://rzp.io/rzp/l5Oit61a)

Even ₹10 / $0.12 helps. Thank you for supporting independent open-source work.

---

## Credits

**Created by [Zusta Digital](https://www.zustadigtal.com) — www.zustadigtal.com**

Built with Claude Opus 4.7, GLM 5.1 Cloud via Ollama, and a lot of debugging.

If you ship something cool with this stack, tag us — we'd love to see it.

---

## Keywords

Claude Code, Claude Max, Claude Opus 4.7, GLM 5.1 Cloud, Ollama, Anthropic, multi-model AI, LLM router, AI coding assistant, dual model, Claude Code subagents, OAuth proxy, AI orchestration, SaaS development, AI agent framework, extended thinking, macOS developer tools, Zhipu GLM, Anthropic OAuth, Claude subscription, AI delegation, staff engineer AI.

---

## License

Released under the MIT License. See [LICENSE](./LICENSE) for details.

If you use this in a commercial product, a link back to this repo and the Zusta Digital site is appreciated but not required.
