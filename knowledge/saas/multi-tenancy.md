# Multi-tenancy patterns — reference knowledge pack

Consulted by `glm-architect`, `glm-schema-designer`, `glm-api-designer`, `glm-security-auditor` when designing tenant-scoped features.

## The three models

### 1. Shared schema, `tenant_id` column (most SaaS)

Every tenant's data lives in the same tables, scoped by a `tenant_id` column. Query filters: `WHERE tenant_id = $current_tenant`.

**Pros:** operationally simple, cheap, easy schema migrations, cross-tenant analytics trivial.
**Cons:** requires airtight query discipline (one missing `WHERE tenant_id` = data leak), noisy-neighbor risk, per-tenant backup is awkward.

**Use for:** 10 to 100k tenants with similar data shape. **This is the default for most SaaS.**

### 2. Schema-per-tenant (Postgres `SET search_path`)

Same database, separate schema per tenant. Connection switches schema on login.

**Pros:** natural isolation at the DB layer, per-tenant backup via schema dump, connection-level tenant scoping (no `WHERE` needed), clearer in audits.
**Cons:** schema migrations are N-times-the-work (need to migrate every tenant schema), Postgres chokes past ~1000 schemas, harder cross-tenant analytics.

**Use for:** 10 to 500 tenants where isolation matters for compliance (regulated industries, enterprise).

### 3. Database-per-tenant

Separate Postgres / MySQL instance per tenant.

**Pros:** maximum isolation (one tenant can't crash another), independent scaling, per-tenant backup/restore trivial, per-tenant data residency possible, noisy-neighbor impossible.
**Cons:** very expensive (N DB instances), complex operations (N connection pools, N migrations, N monitoring targets), cross-tenant analytics requires ETL.

**Use for:** < 100 enterprise tenants, compliance-heavy (HIPAA, finance), per-region data residency requirements.

## The decision matrix (pick one, stick with it)

| Tenants expected | Data sensitivity | Primary workload | Recommended |
|---|---|---|---|
| 10k–100k+ | Medium | OLTP SaaS | Shared schema + `tenant_id` |
| < 1000 | High (regulated) | OLTP SaaS | Schema-per-tenant |
| < 100 | Very high (enterprise, data residency) | OLTP + per-tenant customization | DB-per-tenant |
| Hybrid | Mixed | Multi-product | Shared schema per product, separate infrastructure per product line |

**Do not** mix models within one product. Pick one and commit.

## Implementation: shared schema + `tenant_id`

### The defense-in-depth approach

**Level 1 — Application layer:** every DB query filters by `tenant_id`. Use an ORM with a default scope, or wrap all queries in a repository pattern where the tenant context is required.

```ts
// Repository pattern — tenant context REQUIRED
class InvitationRepo {
  constructor(private db: DB, private tenantId: string) {}
  findById(id: string) {
    return this.db('invitations').where({ id, tenant_id: this.tenantId }).first();
  }
}
```

**Level 2 — Database layer (Postgres RLS):** even if app-layer code forgets, RLS enforces. Catches regressions that app-layer review misses.

```sql
-- Enable RLS
ALTER TABLE invitations ENABLE ROW LEVEL SECURITY;

-- Policy: only rows matching current_setting('app.tenant_id') are visible
CREATE POLICY tenant_isolation ON invitations
  USING (tenant_id::text = current_setting('app.tenant_id', true));

-- In the app, set the session variable on every connection acquire:
SET app.tenant_id = '<current_tenant_id>';
```

Now even a rogue `SELECT * FROM invitations` from application code returns only the current tenant's rows.

**Level 3 — Observability:** alert on any query that returns >N rows at once for a single user — likely indicates a missing WHERE filter or broken RLS.

### Common mistakes caught in review

1. **`JOIN` without tenant filter on the joined table** — `SELECT * FROM a JOIN b ON a.b_id = b.id WHERE a.tenant_id = X` leaks `b` rows from other tenants if not filtered
2. **`UNION` losing tenant context** — each subquery needs its own filter
3. **Raw SQL via `.raw()`** — bypasses ORM default scope; RLS is the backstop
4. **Search endpoints** — full-text search indexes must include `tenant_id` as a filter dimension
5. **Background jobs** — queue workers must load tenant context before processing; don't just operate on raw IDs
6. **Admin impersonation** — internal admin dashboards accidentally show all tenants; enforce tenant scope there too
7. **Analytics queries** — ad-hoc "show me all active users" from the DB shell leaks across tenants
8. **File storage paths** — if you store files at `/uploads/<user_id>/<filename>`, cross-user access via path traversal is trivial. Prefix with `<tenant_id>/<user_id>/<random>/<filename>`.

## Tenant context propagation

Every request's lifecycle:

```
HTTP request arrives
  ↓
Auth middleware: load user → load user.tenant_id → set context
  ↓
Request handler: receives request context with tenant_id
  ↓
DB layer: ALL queries filter by tenant_id (enforced by repo/RLS)
  ↓
Background job enqueued: tenant_id included in job payload
  ↓
Worker picks up job: sets tenant context before processing
  ↓
Response sent
```

Use Node `AsyncLocalStorage`, Python `contextvars`, Ruby `Thread.current`, or explicit context objects — don't rely on globals. A single forgotten filter is a data breach.

## Tenant-level features (nice to design in early)

- **Per-tenant feature flags** — different plans get different features. Use a flags table + middleware that resolves flags from tenant metadata.
- **Per-tenant rate limits** — enterprise tenants get higher limits. Rate-limit middleware keyed by `tenant_id`, lookup limits from tenant config.
- **Per-tenant branding/customization** — logo, color, email "from" address, custom domain. Store as tenant metadata.
- **Per-tenant data export / deletion** — GDPR / SOC2 compliance requires "give me all my data" and "delete my data." Design the extract/purge queries early, not in panic later.
- **Tenant usage metering** — for billing. Track API calls, storage, user count per tenant. See `knowledge/saas/stripe-billing.md`.

## Cross-tenant operations (carefully)

Some operations intentionally cross tenants (admin analytics, marketplace, compliance exports). For these:

- **Use a separate "superuser" database role** with RLS bypassed — never use it in normal request handlers
- **Log every cross-tenant query** with the admin user ID and justification
- **Require two-person approval** for bulk cross-tenant operations (exports, deletions)
- **Rate limit cross-tenant queries** — they're expensive and a leaked cred could dump everything

## Migration: single-tenant → multi-tenant

If you started single-tenant and need to retrofit:

1. Add `tenant_id` column (nullable) to every user-data table
2. Create a default tenant for existing data, backfill
3. Add `NOT NULL + FK` constraint on `tenant_id`
4. Add indexes on `(tenant_id, <existing_id>)` for all common queries
5. Enable RLS with policies
6. Update all queries / repositories to pass tenant context
7. Migrate auth to include tenant in session / JWT
8. Test: spin up 2 tenants, verify queries don't cross

This migration is weeks of work and high-risk. Start multi-tenant from day 1 if you know you'll need it.

## Specific Postgres tricks

- **`CREATE INDEX ON invitations (tenant_id, created_at DESC)`** — tenant_id is almost always the first column in every index
- **Partitioning by tenant_id** for very large tenants (list partitioning) — improves query plans and enables per-tenant VACUUM
- **Separate "free" vs. "paid" DB instances** via logical replication — noisy-neighbor prevention
- **Per-tenant connection pooling** (PgBouncer with `server_lifetime` per pool) — for schema-per-tenant model

## Anti-patterns

- **Using the tenant_id in URLs** (`/tenant/42/invoices`) — leak tenant IDs, invite scanning. Use subdomains (`acme.yoursaas.com`) or opaque slugs.
- **Storing tenant config in a single "tenants" table that's pulled on every request** without caching — DB roundtrip per request. Cache in Redis, invalidate on config change.
- **Cross-tenant UNIQUE constraints on things that should be per-tenant unique** — `UNIQUE(email)` is wrong; `UNIQUE(tenant_id, email)` is right for a shared-schema SaaS
- **Hard-coding the "first tenant" ID in seed data** — makes tests brittle; use factories
