# Ollama Outage Policy

## What happens when Ollama is unreachable

The claude-dual proxy's per-provider circuit breaker detects Ollama failures and
manages outage state automatically. This doc explains the behavior, how to detect
it, and what manual actions to take.

## Detection

1. **Circuit breaker opens** after `CIRCUIT_THRESHOLD` (default: 5) consecutive
   failures to any Ollama endpoint. All subsequent Ollama requests receive
   HTTP 503.

2. **Audit trail events** are emitted to `audit.jsonl`:
   - `ollama_outage_start` — breaker transitioned to OPEN
   - `ollama_outage_active` — repeated every 5 minutes while OPEN
   - `ollama_outage_end` — breaker transitioned back to CLOSED

3. **Health endpoint:** `GET /health` includes:
   ```json
   "ollama_outage": {"active": true, "since": "2026-04-26T10:00:00.000Z"}
   ```

4. **Logs:** `logger.warn` with `event: 'circuit_open', provider: 'ollama'`
   appears on first detection.

## Recovery (automatic)

- After `CIRCUIT_RESET_MS` (default: 30s), the breaker transitions to
  half-open, allowing one probe request.
- If the probe succeeds: breaker closes, outage events stop, normal service
  resumes.
- If the probe fails: breaker re-opens, interval warning continues.

## Manual fallback (recommended during prolonged outage)

When Ollama stays down for more than a few minutes (e.g., local service crash,
model unloaded, out-of-disk):

1. **Temporarily skip GLM dispatch.** In claude-dual orchestration, Opus should
   do GLM-destined work directly instead of delegating. This avoids 503 storms
   and wasted proxy retries.

2. **Verify the proxy is still serving** by checking `/health` — Anthropic
   requests are unaffected since the circuit breaker is per-provider.

3. **Restore Ollama** by restarting the service or reloading the model. Once
   the breaker half-open probe succeeds, routing resumes automatically.

4. **Recovery is silent** — the `ollama_outage_end` audit event confirms the
   breaker has closed. No manual reset is needed.

## Audit event summary

| Event | Trigger | Payload |
|---|---|---|
| `ollama_outage_start` | Breaker transitions from closed/half-open to open | `{event, ts}` |
| `ollama_outage_active` | Emitted every 5 min while open | `{event, ts}` |
| `ollama_outage_end` | Breaker transitions back to closed | `{event, ts}` |
