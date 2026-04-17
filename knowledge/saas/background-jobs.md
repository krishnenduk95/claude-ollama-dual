# Background jobs — reference knowledge pack

Consulted by `glm-architect`, `glm-api-designer`, `glm-worker` when designing async / queued / scheduled work.

## When to use background jobs (not always)

**Inline is fine if:**
- The work completes in < 200ms
- Failure is acceptable to surface to the user immediately
- Idempotency isn't critical
- There's no retry requirement

**Use a background job when:**
- The work takes > 1 second (sending email, generating PDF, computing analytics)
- The work can fail and needs retries (webhook delivery, API calls to flaky services)
- The work is fire-and-forget from the user's perspective (invalidating caches, sending notifications)
- The work needs to be scheduled (daily reports, expiring tokens, cleanups)
- The work is expensive and you want to rate-limit / prioritize it
- The work needs guaranteed execution (money, user-visible state changes)

**Rule of thumb:** if the user wouldn't notice/care if this failed, or if failure should NOT block their request — it's a job.

## Queue infrastructure (pick one)

### Redis-based (BullMQ, Sidekiq, RQ, Resque)

**Pros:** low latency (< 1ms enqueue), simple setup, widely-used, good tooling (Bull Board, Sidekiq Web)
**Cons:** Redis persistence is best-effort by default — configure AOF fsync for durability; Redis costs increase with queue depth

**Use for:** most SaaS up to ~100 jobs/sec per queue

### Postgres-based (Graphile Worker, Que, Oban)

**Pros:** no extra infrastructure (uses your existing Postgres), transactional with your business data (enqueue + commit in one TX), strong durability, easy dead-letter management
**Cons:** polling overhead, lower throughput ceiling (~1000 jobs/sec before tuning needed), long-running jobs lock rows

**Use for:** small-to-medium SaaS, anything under 100 jobs/sec, teams already running Postgres

### Dedicated queue (SQS, Google Pub/Sub, RabbitMQ, NATS)

**Pros:** higher throughput, better for microservices, long message retention
**Cons:** more infrastructure, more surface area for errors, higher ops overhead

**Use for:** > 1000 jobs/sec, cross-service message passing, durability-critical

### Cron / scheduled tasks

Use whatever your infrastructure provides:
- Kubernetes: `CronJob` resource
- Docker Compose: a separate service running `crond`
- Single server: actual `cron`
- Serverless: Cloudflare Cron Triggers, EventBridge, GCP Cloud Scheduler
- Embedded: `node-cron`, `APScheduler`, `rufus-scheduler`

Never roll your own cron in-app with `setInterval` — it doesn't survive restarts, doesn't handle multiple instances, and loses state.

## The five jobs your SaaS will need

### 1. Email sending
Every signup / password reset / notification goes through here. Rate-limit, retry on transient failures, dead-letter permanent failures.

### 2. Webhook delivery
Your API has webhooks (outgoing to customers). Must retry with exponential backoff for up to 24+ hours. Store payload, store delivery attempts, let customers replay.

### 3. Data processing / report generation
"Generate monthly report for tenant X" — user-triggered, takes 30 seconds, result stored in S3 / DB.

### 4. Scheduled maintenance
Daily: expired-token cleanup, usage aggregation, billing sync. Weekly: sending digest emails, recomputing per-tenant analytics.

### 5. Integration sync
Pull from Stripe webhook backlog, push to Intercom/HubSpot/Salesforce, sync with user's Slack workspace.

## Job design principles

### Idempotency is non-negotiable

Every job can run more than once — process crash, retry, duplicate enqueue. Your job function MUST handle this correctly:

```js
// BAD — sends two emails if job runs twice
async function sendWelcomeEmail(userId) {
  const user = await db.getUser(userId);
  await mailer.send(user.email, 'welcome', { ... });
}

// GOOD — uses a dedupe key; second run is a no-op
async function sendWelcomeEmail(userId) {
  const key = `welcome_email:${userId}`;
  const acquired = await redis.set(key, '1', 'NX', 'EX', 86400);
  if (!acquired) return;  // already sent (or in-flight)
  const user = await db.getUser(userId);
  await mailer.send(user.email, 'welcome', { ... });
}
```

Or use a database flag: `users.welcome_email_sent_at IS NULL` → send → set timestamp in same transaction.

### Short, single-concern jobs

Don't build "process-customer-onboarding" that does 10 things. Build 10 jobs that each do one thing, chain them with `await` in a parent job or use a workflow engine.

Why:
- Easier to retry a specific failed step without redoing the whole thing
- Easier to observe (what's running, what's stuck)
- Easier to deploy (changing step 3 doesn't require redeploying step 1)
- Easier to reason about failure modes

### Explicit inputs, explicit outputs

Job argument is a small object with all the inputs. Don't rely on implicit globals or "the job will load the user from DB." If the job needs user data, pass `userId`; if it needs the tenant context, pass `tenantId`. The job handler is responsible for loading what it needs.

```ts
// Explicit
queue.add('send_invoice', { invoiceId: '...', tenantId: '...', attemptContext: { ... } });
```

### Tenant context in every job

See `knowledge/saas/multi-tenancy.md` — tenant context MUST propagate through jobs. Include `tenant_id` in every job payload; set it in `AsyncLocalStorage` / `contextvars` at the start of the worker handler.

### Timeouts

Every job has a hard timeout. If it takes longer than expected, kill it. Otherwise:
- A single slow job blocks the worker
- You can't distinguish "working" from "stuck"
- Retries pile up behind it

Default: 5 minutes for most jobs; 30 seconds for email/webhook; 1 hour for report generation (adjust to real task size).

## Retry strategy

### Exponential backoff with jitter

Never retry immediately. Classic schedule:
- Attempt 1: fail
- Retry after 1s + jitter
- Retry after 4s + jitter
- Retry after 15s + jitter
- Retry after 60s + jitter
- Retry after 5m + jitter
- Retry after 30m + jitter
- Move to dead-letter queue

Jitter prevents the "thundering herd" when 1000 jobs retry simultaneously.

### Categorize errors

Not every error deserves retry:

```js
async function runJob(job) {
  try {
    return await handler(job);
  } catch (err) {
    if (err.transient) throw new RetryableError(err);   // retry
    if (err.validation) throw new PermanentError(err);  // dead-letter immediately
    throw err; // default to retry
  }
}
```

- **Transient (retry):** network timeouts, 5xx from upstream, DB deadlock, rate-limited
- **Permanent (dead-letter):** 4xx from upstream (bad input), validation errors, "user not found"
- **Unknown (default retry with caps):** default to retry with reasonable max attempts (e.g., 8)

### Dead-letter queue

Jobs that exhaust retries go to a DLQ for manual investigation. Never silently drop.

## Observability

Metrics to track per queue:
- **Jobs enqueued** / sec
- **Jobs processed** / sec
- **Job duration** p50/p95/p99
- **Job failures** / sec (and by error type)
- **Queue depth** (backlog) — alert if growing unboundedly
- **Worker utilization** — alert if consistently > 80% (need more workers)
- **Oldest job age** — alert if jobs aging past SLA

Log structured:
```json
{
  "event": "job_end",
  "job_id": "...",
  "job_type": "send_email",
  "tenant_id": "...",
  "duration_ms": 432,
  "attempt": 1,
  "status": "success"
}
```

## Scaling

### Vertical: one worker process with N concurrency
```
Worker → reads job → processes up to CONCURRENCY in parallel → next job
```

BullMQ default CONCURRENCY=1. Bump to 5-10 for I/O-bound jobs; keep at 1 for CPU-bound.

### Horizontal: multiple worker processes
Scale out by adding processes, usually via Kubernetes HPA or your hosting platform's scaling. Jobs distribute automatically via queue.

### Per-queue priority
Most libraries let you prioritize queues. Typical setup:
- `critical` (1 worker always dedicated) — webhooks, email sending
- `default` (N workers, autoscaled) — most jobs
- `low` (1 worker, runs when idle) — analytics aggregation, cleanup

Don't mix long-running jobs with short ones in the same queue — 30s jobs will starve 300ms jobs. Put them in separate queues.

## Anti-patterns

- **Polling a DB from a queue worker** — "check every 5 seconds if any job needs doing" is not a queue, it's a loop. Use a real queue.
- **Fire-and-forget without persistence** — if your process dies, the job is lost. Use a durable queue.
- **Unbounded retry** — some jobs should never succeed; dead-letter them after N attempts.
- **Mixing business logic and infrastructure** in job handlers — abstract the work into a function, let the handler only orchestrate retry/observability around it.
- **Building your own distributed queue** — just use Bull / Sidekiq / Graphile / SQS. There's more subtlety in queue semantics than you think (at-least-once vs exactly-once, ordering, visibility timeouts).
- **Using jobs for request-response** — if the user is waiting for a result, do it inline or implement a proper async-API pattern (submit → get job ID → poll). Don't block the HTTP handler on queue.add + await.

## Testing

- **Unit test the job function** in isolation with mocked dependencies. Don't spin up Redis for unit tests.
- **Integration test** with a real queue (testcontainers for Redis) — assert that enqueuing + processing produces the right side effects.
- **Contract test** — if a job calls an external API, have a fake API server (MSW / Mountebank / nock) that returns canned responses including failures.
- **Load test** the queue before production — enqueue 10000 jobs of various types, measure throughput and p99 latency.
- **Chaos test** — kill workers mid-processing, disconnect Redis during a run, verify no jobs are lost (at-least-once) or duplicated silently (beyond idempotency).

## Libraries

- **Node:** BullMQ (new), Bull (old), agenda, bree, graphile-worker (Postgres)
- **Python:** Celery (mature), RQ (simple), dramatiq, arq (async)
- **Ruby:** Sidekiq (industry standard), GoodJob (Postgres), Resque
- **Go:** river (Postgres), asynq (Redis), taskq
- **Cross-language:** SQS + any worker framework, Temporal (workflows)
