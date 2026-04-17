# Security Policy

## Supported versions

Only the latest `main` branch / latest tagged release receives security updates.

| Version | Supported |
|---------|-----------|
| latest `main` / most recent tag | ✅ |
| everything else | ❌ |

## Reporting a vulnerability

**Please do NOT open public GitHub issues for security vulnerabilities.**

Report privately via one of these channels:

1. **GitHub Security Advisory** (preferred): [Report a vulnerability](https://github.com/krishnenduk95/claude-ollama-dual/security/advisories/new)
2. **Email:** security at zustadigtal dot com (replace "at"/"dot" with @/.)

Please include:

- A description of the vulnerability
- Steps to reproduce (or a proof-of-concept)
- Affected versions / commits
- Your assessment of impact

## Response SLA

- **Acknowledge** within 48 hours
- **Status update** within 5 business days
- **Fix + disclosure** coordinated once the fix is ready (typically 7–30 days depending on severity)

## Scope

**In scope:**

- The proxy (`proxy/proxy.js`): OAuth handling, routing logic, rigor injection, auth check, rate limiting, circuit breaker
- Install / uninstall scripts (`install.sh`, `install.ps1`, `uninstall.sh`)
- Subagent system prompts (`agents/*.md`) — if a prompt could be coerced into leaking credentials or exfiltrating code
- CI workflows (`.github/workflows/`) — if they could expose secrets

**Out of scope:**

- Vulnerabilities in Anthropic's API (report to Anthropic)
- Vulnerabilities in Ollama or Ollama Cloud (report to Ollama)
- Vulnerabilities in the GLM model itself (report to Z.ai)
- Vulnerabilities in Node.js runtime or bundled dependencies (report upstream; we'll track + update once the CVE is public)
- Third-party forks

## Disclosure

Once a fix is available, we'll publish a GitHub Security Advisory crediting the reporter (unless you prefer to remain anonymous). The advisory will include:

- Affected versions
- Fix commit / release
- CVE ID (if assigned)
- Mitigations for users who can't upgrade immediately

## Bounty

We don't currently run a paid bounty program. If the vulnerability is serious and well-researched, we'll publicly credit you and (as an individual, not a corporate promise) tip via [our donation page](https://rzp.io/rzp/l5Oit61a) if we can.
