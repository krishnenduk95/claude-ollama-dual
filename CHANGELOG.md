# Changelog

All notable changes to this project will be documented here.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and (from v1.0.0 onward) uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Planned

- Docker image + compose file for containerized deployment
- Grafana dashboard + Prometheus alert rules
- Bedrock/Vertex failover providers
- Web dashboard for routing stats + cost tracking

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
