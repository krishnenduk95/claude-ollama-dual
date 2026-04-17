# Auth flows for SaaS — reference knowledge pack

Consulted by `glm-architect`, `glm-api-designer`, `glm-security-auditor`. When a task involves login, signup, password reset, sessions, OAuth, or MFA, reference this pack.

## Decision: session vs. JWT vs. OAuth

| Approach | Use when | Don't use when |
|---|---|---|
| **Server-session (cookie)** | First-party web app, same-origin | Native mobile app only, no browser |
| **JWT** | Stateless API, multi-service, mobile | You need session revocation without rebuild |
| **OAuth 2.0 / OIDC** | Delegating identity to Google/GitHub/Microsoft | Internal tools with simple email/password |

**Default for new SaaS:** server-session for web + JWT for mobile/API, both issued by the same auth service. Don't default to JWT-everywhere "because it's stateless" — session revocation is the killer.

## Password storage (non-negotiable)

- **Algorithm:** argon2id (preferred), bcrypt (acceptable), scrypt (OK). NEVER MD5/SHA1/SHA256-without-salt.
- **Bcrypt cost:** ≥12 in 2026 (adjust upward as CPUs get faster)
- **Argon2 params:** memory 64 MB, iterations 3, parallelism 4 — verify against OWASP cheat sheet at implementation time
- **Pepper:** optional extra secret in env, not stored in DB, XOR/HMAC into hash. Limits DB-only dump damage.
- **NEVER** log passwords. Not raw, not hashed, not in debug mode.

## Login endpoint checklist

- [ ] Rate limit by IP (5/min) and by account (5/min/account)
- [ ] Constant-time password comparison (`bcrypt.compare` is OK; never `===` on hashes)
- [ ] Uniform error response: "Invalid email or password" — don't disclose which was wrong
- [ ] Constant-time behavior: if the email doesn't exist, still run a dummy hash so timing doesn't leak
- [ ] Rotate session ID on successful login (prevents session fixation)
- [ ] Lock account after N consecutive failures (N=10) with exponential cooldown
- [ ] CAPTCHA after N IP-level failures (hCaptcha / Cloudflare Turnstile)
- [ ] Log successful login (IP, user-agent, timestamp) to security audit log
- [ ] Log failed login (email attempted, IP, timestamp) — for abuse detection
- [ ] Set session cookie with `HttpOnly`, `Secure`, `SameSite=Lax` (or `Strict` for pure-first-party)

## Password reset flow (the #1 source of bugs)

Canonical flow:
1. User submits email → respond 200 regardless of existence (don't leak user enumeration)
2. Generate token = `crypto.randomBytes(32).toString('base64url')`
3. Store hashed token in DB: `password_reset_tokens(user_id, token_hash, expires_at, used_at NULL)`
4. Email plaintext token to user (1-hour expiry)
5. User clicks link → GET `/reset?token=<token>` → render form
6. User submits new password → POST `/reset` with `token + new_password`
7. Verify: token exists, not expired, `used_at IS NULL`
8. If valid: hash and save new password, set `used_at = NOW()`, invalidate ALL user sessions, email confirmation

**Security rules:**
- Token must be single-use (`used_at` check)
- Token must expire (1 hour max, 15 minutes preferred)
- On password change via reset, revoke ALL existing sessions
- Hash the token in DB (same way you'd hash passwords — prevents DB dump from enabling resets)
- Rate-limit the "request reset" endpoint (3/hour/email)
- Constant response time whether email exists or not
- Never include the user's current password in the reset email
- Never include the user's ID or other info in the reset URL — only the token

## Session management

### Cookie-based sessions

```
Set-Cookie: sid=<opaque-random-string>; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=<seconds>
```

- **Session ID length:** ≥128 bits of entropy (`crypto.randomBytes(32)`)
- **Storage:** Redis / memcached with TTL. Don't store session data in JWT; use sessionID → lookup.
- **Absolute lifetime:** 30 days max (rolling)
- **Idle lifetime:** 24 hours (re-requires activity)
- **Revocation:** deleting the row in Redis = immediate logout across all devices

### JWT-based sessions (for APIs)

- **Access token:** short-lived (15 min), signed with HS256 or RS256
- **Refresh token:** long-lived (30 days), single-use, rotated on each refresh, stored in DB
- **Key rotation:** `kid` header, support multiple keys simultaneously for rolling rotation
- **NEVER put sensitive data in JWT claims** — assume they're readable by the client
- **Validate:** signature, expiry (`exp`), issuer (`iss`), audience (`aud`), revocation list
- **Revocation:** you need a DB check on every request for revoked refresh tokens; pure-JWT without this = no logout

## MFA (multi-factor authentication)

- **TOTP (Google Authenticator style):** `otplib` library, 30-second window, 6 digits. Store shared secret encrypted per-user.
- **WebAuthn / Passkeys:** preferred over TOTP in 2026. Use `@simplewebauthn/server`.
- **SMS:** weakest form (SIM swap), avoid for high-value accounts
- **Backup codes:** generate 10 single-use codes at MFA enrollment, user downloads them

When implementing MFA:
- Separate endpoint after password check: `/login` returns `mfa_required: true` with an `mfa_token` (short-lived, single-use), then `/login/mfa` takes the `mfa_token + code`
- Don't short-circuit: MFA must be enforced server-side, not just UI-hidden
- Rate limit MFA attempts (5 failures → lockout for 15 min)

## OAuth 2.0 / OIDC (delegated auth)

When integrating "Sign in with Google/GitHub/etc.":

- Use a library: `next-auth` / `passport` / `authlib` / `oauth2-server` — never roll your own
- **Always** validate `state` parameter (prevents CSRF in auth flow)
- **Always** use PKCE (S256 challenge) for public clients
- **Verify** the ID token signature using the provider's JWKS endpoint (cached, refreshed)
- **Validate** `iss`, `aud`, `exp`, `nonce`
- Map OAuth identity to your user accounts with care — if email from Google matches existing account, DON'T auto-link without verification (allows account takeover)

## Common mistakes caught in review

1. **Unverified email used for login** — attacker registers with their email claiming to be `victim@corp.com`, gets access
2. **`verify_token(token) === token_from_db`** — string comparison in Node is not constant-time; use `crypto.timingSafeEqual`
3. **Password reset token in URL fragment** — not sent to server, but visible in browser history and referrers
4. **Refresh token rotation bug** — old refresh token still valid after use, enables replay
5. **MFA bypassed via password reset** — password reset must NOT automatically disable MFA
6. **Session not rotated on login** — enables session fixation via XSS + cookie injection
7. **Logout that only deletes client cookie** — server session still live, still works via replay
8. **Hard-coded JWT secret in `.env` committed to git** — check git history, not just current state
9. **Rate limit shared across all users** — per-IP limit doesn't help when attacker has 1000 IPs; add per-account
10. **Passwordless "magic links" that never expire** — treat like password reset tokens: 15-min expiry, single-use

## Libraries to reach for (2026)

- **Node:** `bcryptjs`, `argon2`, `jose` (JWT), `iron-session` (cookies), `@simplewebauthn/server` (passkeys)
- **Python:** `argon2-cffi`, `PyJWT`, `authlib` (OAuth), `webauthn` (passkeys)
- **Go:** `golang.org/x/crypto/bcrypt`, `golang.org/x/crypto/argon2`, `github.com/golang-jwt/jwt`
- **Full-stack auth systems:** NextAuth.js, Clerk (managed), WorkOS (managed), Auth0 (managed)

## When to buy vs. build

**Buy** (Clerk / Auth0 / WorkOS) if:
- You're early-stage and auth isn't your product
- You need enterprise SSO (SAML) soon
- Your team lacks security expertise

**Build** if:
- You have specific compliance requirements that SaaS auth providers don't meet
- You need tight customization (passwordless-only, novel MFA)
- Auth IS your product

Most SaaS < $10M ARR should buy. Your time is better spent elsewhere.
