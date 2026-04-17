# Contributing to claude-dual

Thanks for your interest. This project is small, practical, and opinionated — PRs welcome, especially for the things listed below.

## What contributions are most welcome

- **Bug fixes** with a failing test first, then the fix
- **New provider support** (Bedrock, Vertex, Azure OpenAI, OpenRouter, direct Z.ai) via routing additions in `proxy/proxy.js`
- **Cross-platform improvements** (especially Linux + Windows, the macOS path is well-tested)
- **Tests** — we could always use more, especially for the HTTP handler
- **Documentation clarity** — if something in the README was confusing, send a PR fixing it
- **Observability recipes** — Grafana dashboards, Prometheus alert rules, log-aggregation configs

## What's out of scope (please discuss first)

- Breaking changes to the delegation rule or subagent system prompts
- Adding heavy dependencies (we like zero-dep, fall back when optional deps are absent)
- Adopting a framework (Express, Fastify) for the proxy — vanilla `http` is a feature
- Feature flags / A/B infrastructure

## Set up locally

```bash
git clone https://github.com/krishnenduk95/claude-ollama-dual.git
cd claude-ollama-dual

# Install proxy deps (for tests + structured logging)
cd proxy
npm install
npm test
npm run lint
cd ..

# Syntax-check the installers
bash -n install.sh
bash -n uninstall.sh
```

You don't need Claude Max or Ollama installed to run tests — the unit tests exercise pure logic.

## Running the proxy locally (without installing)

```bash
cd proxy
node proxy.js
# In another terminal:
curl -s http://127.0.0.1:3456/health
curl -s http://127.0.0.1:3456/metrics
```

## PR process

1. **Fork + branch** — branch name like `fix/circuit-breaker-half-open` or `feat/bedrock-failover`
2. **Make your change small** — one concern per PR. Two features = two PRs.
3. **Tests required** for any logic change. Use `node --test` (the Node built-in runner — no extra framework).
4. **Run the checks** locally:
   ```bash
   cd proxy && npm test && npm run lint
   bash -n install.sh
   ```
5. **CHANGELOG entry** under `[Unreleased]` in `CHANGELOG.md`
6. **Open a PR** using the template; link the issue if one exists
7. **Be patient** — this is maintained in spare time

## Commit style

Plain English imperative, no enforced format:

```
Add Bedrock failover provider

Proxy now retries on Anthropic circuit-open by falling back to Bedrock
via BEDROCK_ENDPOINT env var. Tested with AWS_PROFILE=dev.
```

Short first line (≤72 chars), blank line, body with the why.

## Code style

- Vanilla Node (no framework, no TypeScript)
- 2-space indent, single quotes, semicolons
- `'use strict'` at the top of Node files
- Keep functions short; extract when a function does two things
- Comment the **why**, not the what — except for subtle invariants

## Subagent system prompts

If you're editing `agents/glm-*.md`, the bar is high:

- Keep the rigor framework intact — don't water it down
- Test changes by dispatching the subagent on a representative task (see `tests_quality/` for examples)
- If you add a new agent (e.g., `glm-tester.md`), update `CLAUDE.md` and `README.md` to include it in the delegation table

## Reporting security issues

See [SECURITY.md](./SECURITY.md). Do NOT open public issues for vulnerabilities.

## License

By contributing, you agree that your contributions will be licensed under the MIT License (same as the project).
