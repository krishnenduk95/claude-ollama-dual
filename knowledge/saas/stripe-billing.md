# Stripe billing integration — reference knowledge pack

Consulted by `glm-architect`, `glm-api-designer`, `glm-security-auditor` when designing pricing, subscriptions, payments, or billing. Principles apply to Stripe; 90% translate to Paddle / Lemon Squeezy / Chargebee.

## The mental model

Stripe's data model you'll be integrating with:

- **Customer** — a person or business that pays. Maps 1:1 to your tenant or user.
- **Product** — something you sell ("Pro Plan")
- **Price** — the price for a product ($20/month, $200/year). A product has many prices.
- **Subscription** — customer subscribed to a price, billed recurringly
- **Invoice** — bill generated per billing period (subscription invoice) or ad-hoc
- **Payment Intent** — attempt to charge
- **Webhook event** — Stripe tells you something happened asynchronously

**Your mental model rule:** Stripe is the source of truth for billing state. Your DB caches what Stripe tells you via webhooks. Never decide "is this user subscribed?" based on your DB alone — always verify via Stripe in critical paths, or trust webhooks that you've idempotently stored.

## Schema you'll need (minimal)

```sql
-- Maps your tenant to Stripe customer
CREATE TABLE billing_customers (
  tenant_id UUID PRIMARY KEY REFERENCES tenants(id),
  stripe_customer_id TEXT UNIQUE NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Cache of subscription state (source of truth = Stripe; this is read-optimized cache)
CREATE TABLE billing_subscriptions (
  id TEXT PRIMARY KEY,                      -- Stripe subscription ID
  tenant_id UUID REFERENCES tenants(id),
  stripe_customer_id TEXT NOT NULL,
  status TEXT NOT NULL,                     -- active, past_due, canceled, incomplete, trialing, etc.
  price_id TEXT NOT NULL,                   -- which Stripe Price
  current_period_start TIMESTAMPTZ,
  current_period_end TIMESTAMPTZ,
  cancel_at_period_end BOOLEAN DEFAULT false,
  trial_ends_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ DEFAULT NOW()      -- when we last synced from Stripe
);

-- Webhook idempotency
CREATE TABLE stripe_webhook_events (
  id TEXT PRIMARY KEY,                      -- Stripe event.id (idempotency key)
  event_type TEXT NOT NULL,
  processed_at TIMESTAMPTZ DEFAULT NOW(),
  raw_payload JSONB                         -- for replay / debugging
);
```

## Integration patterns

### Initial signup with subscription

1. User completes signup → tenant created
2. Create Stripe Customer immediately (or defer until first paid action): `stripe.customers.create({ email, metadata: { tenant_id } })`
3. Store `stripe_customer_id` in `billing_customers`
4. User picks a plan → create Stripe Checkout Session or Billing Portal link
5. Stripe handles card collection, subscription creation, webhook fires
6. Your webhook handler receives `customer.subscription.created` → upsert into `billing_subscriptions`
7. Your app UI re-checks subscription status, unlocks paid features

**Key rule:** don't mark the user as "paid" in your DB until the webhook confirms. Stripe Checkout success doesn't guarantee the subscription was successfully created (3DS, card declined on first charge, etc.).

### Webhook handling (critical — get this right)

```ts
// app/api/stripe/webhook/route.ts
import { Stripe } from 'stripe';
import { headers } from 'next/headers';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!);
const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET!;

export async function POST(req: Request) {
  const body = await req.text();
  const sig = headers().get('stripe-signature');
  if (!sig) return new Response('missing signature', { status: 400 });

  let event: Stripe.Event;
  try {
    event = stripe.webhooks.constructEvent(body, sig, webhookSecret);
  } catch (err) {
    // Signature verification failed — 400 (Stripe retries for 3 days)
    return new Response(`webhook signature failed: ${err.message}`, { status: 400 });
  }

  // Idempotency — have we seen this event ID before?
  const existing = await db.query(
    'SELECT id FROM stripe_webhook_events WHERE id = $1',
    [event.id]
  );
  if (existing.rows.length) {
    // Already processed — return 200 so Stripe stops retrying
    return new Response('already processed', { status: 200 });
  }

  // Process in a transaction with event record
  await db.transaction(async (tx) => {
    await tx.query(
      'INSERT INTO stripe_webhook_events (id, event_type, raw_payload) VALUES ($1, $2, $3)',
      [event.id, event.type, JSON.stringify(event.data.object)]
    );

    switch (event.type) {
      case 'customer.subscription.created':
      case 'customer.subscription.updated':
      case 'customer.subscription.deleted':
        await upsertSubscription(tx, event.data.object as Stripe.Subscription);
        break;

      case 'invoice.payment_failed':
        await handlePaymentFailed(tx, event.data.object as Stripe.Invoice);
        break;

      case 'customer.subscription.trial_will_end':
        // 3 days before trial ends — send reminder email
        await queueTrialEndingEmail(tx, event.data.object);
        break;

      // ... other events
    }
  });

  return new Response('ok', { status: 200 });
}
```

**Rules for the webhook endpoint:**

1. **ALWAYS verify the signature** before processing — unsigned requests could be attackers
2. **Idempotency via event.id** — Stripe sends duplicates; your handler must handle them safely
3. **Return 200 as fast as possible** (< 5 seconds) — Stripe retries for 3 days if you don't
4. **Wrap in a DB transaction** with the event insert — guarantees the event is recorded with the state change
5. **Handle every event type you care about explicitly** — don't do `default: process(...)`
6. **No long-running work in-handler** — queue heavy work (emails, feature provisioning) to a job queue

### Subscription state → your app's feature gates

Whenever your app needs to check "is this tenant on the Pro plan?":

```ts
async function hasProFeatures(tenantId: string): Promise<boolean> {
  const sub = await db.query(
    'SELECT status, current_period_end, price_id FROM billing_subscriptions WHERE tenant_id = $1',
    [tenantId]
  );
  if (!sub.rows.length) return false;
  const { status, current_period_end, price_id } = sub.rows[0];

  // Active only if status is "active" or "trialing", and period hasn't ended
  const activeStatus = ['active', 'trialing'].includes(status);
  const periodOk = new Date(current_period_end) > new Date();
  const planOk = PRO_PRICE_IDS.includes(price_id);

  return activeStatus && periodOk && planOk;
}
```

Use this check in middleware or at feature-gate seams. Cache the result for 30-60s per tenant to avoid hammering your DB.

## Common pitfalls

### 1. Not handling `past_due` and `unpaid` status

A subscription can be `active` today but transition to `past_due` when a renewal payment fails. Your feature gate should check for `active` OR `trialing` — not just non-`canceled`. Users in `past_due` should see a banner and have 7-14 days to fix payment before downgrade.

### 2. Not cleaning up on cancel

When a subscription cancels:
- Keep the subscription row (`status = 'canceled'`) — don't delete history
- Downgrade feature access at `current_period_end` (they paid through this date)
- Don't auto-delete tenant data — let them export / reactivate for 30+ days

### 3. Tax handling

Stripe Tax is the right answer for 90% of cases — enable it, let Stripe handle VAT/GST/sales tax. If you need custom tax logic, you're in for a world of pain (test with Romanian VAT, Indian GST, Canadian GST vs provincial taxes, US sales tax per state, digital-service-specific rules).

### 4. Proration on plan changes

When a user upgrades mid-period, Stripe prorates by default — the user pays a prorated amount for the remainder of the period at the new rate.

Surprises:
- **Proration credits** — if someone downgrades mid-period, they get credit for the unused high-tier time; Stripe applies it to the next invoice. Tell users explicitly.
- **Quantity changes** (seat count) — `proration_behavior: 'create_prorations'` vs `'none'` — pick based on your pricing page copy.

### 5. Testing with real webhooks

Use `stripe cli` in local development:
```
stripe listen --forward-to localhost:3000/api/stripe/webhook
stripe trigger customer.subscription.created
```

Don't test subscription logic by "clicking through Stripe Checkout in staging" — far too slow and flaky. Use `stripe trigger` to fire events directly.

### 6. API key / secret management

- `STRIPE_SECRET_KEY` — server-side only, never commit, never log, never send to client
- `STRIPE_WEBHOOK_SECRET` — specific to each webhook endpoint; rotate if you suspect leak
- **Restricted API keys** — create keys scoped to what they need (e.g., a key that can only create Customers, not read them). Reduces blast radius.

### 7. Metering / usage-based billing

If your pricing is "per API call" / "per MB stored" / "per transaction":
- Meter on your side (write to a usage log table)
- Report to Stripe at end of period: `stripe.subscriptionItems.createUsageRecord`
- OR use Stripe's real-time usage reporting (more complex, trade-off for accuracy)

Test edge cases: user adds seats mid-cycle, usage reporting fails (queue + retry), high-volume tenants (batch the usage records)

## Security checklist

- [ ] Webhook signature verified on every invocation (use `stripe.webhooks.constructEvent`)
- [ ] `STRIPE_WEBHOOK_SECRET` not logged, not in client bundle
- [ ] Event idempotency table prevents duplicate processing
- [ ] Customer Portal links generated per-request (not stored), scoped to authenticated tenant
- [ ] Subscription checks are always server-side (never trust client state)
- [ ] PCI: don't touch raw card data — only accept Stripe Elements / Checkout (keeps you out of PCI-DSS scope)
- [ ] Refunds require admin role — don't let every user refund their own subscriptions
- [ ] Webhook endpoint has no auth BUT signature-verifies (public-by-necessity)
- [ ] Customer impersonation for support requires audit log entry

## Pricing page rules (design discussion)

- Monthly vs annual toggle (usually 17-20% discount on annual)
- Free trial? How long? Does it require a card up front?
- When do you charge? On signup, on trial-end, on first use?
- Can users switch plans mid-cycle? (Yes, Stripe handles proration.)
- Enterprise: "contact sales" → direct CRM link, don't try to self-serve
- Display currency: Stripe Checkout auto-detects; your pricing page should too (via IP geolocation)

## Don't-build-this list

You should use Stripe's managed features rather than re-build:

- **Customer Portal** — Stripe-hosted page where users update payment, cancel, switch plans. Don't build your own "manage subscription" UI.
- **Checkout** — Stripe-hosted checkout page (optional Elements embedded). Don't implement card forms.
- **Tax** — Stripe Tax auto-computes and remits. Don't try to DIY.
- **Invoice emails** — Stripe sends them automatically. Don't re-send your own.
- **Subscription recovery (smart retries)** — Stripe's built-in logic for retrying failed charges. Don't write your own.
- **Fraud detection** — Stripe Radar. Don't try to detect card fraud yourself.

## Libraries

- **Node:** `stripe` (official SDK), TypeScript types ship in the package
- **Python:** `stripe` (official)
- **Go:** `github.com/stripe/stripe-go/v76`
- **Ruby:** `stripe` (official)

Always pin to a specific Stripe API version (`Stripe-Version: 2023-10-16` header). Upgrade the version deliberately, read the migration guide.
