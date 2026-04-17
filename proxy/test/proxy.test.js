'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  classifyModel,
  applyGlmRigor,
  TokenBucket,
  CircuitBreaker,
  trackCost,
  costState,
  PRICING,
  _auth,
} = require('../proxy.js');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── classifyModel ────────────────────────────────────────────────────────
test('classifyModel: Claude model → anthropic', () => {
  assert.deepEqual(classifyModel('claude-opus-4-7'), { provider: 'anthropic', model: 'claude-opus-4-7' });
  assert.deepEqual(classifyModel('claude-sonnet-4-6'), { provider: 'anthropic', model: 'claude-sonnet-4-6' });
  assert.deepEqual(classifyModel('claude-haiku-4-5-20251001'), { provider: 'anthropic', model: 'claude-haiku-4-5-20251001' });
});

test('classifyModel: GLM and other Ollama-style → ollama', () => {
  assert.equal(classifyModel('glm-5.1:cloud').provider, 'ollama');
  assert.equal(classifyModel('qwen3:7b').provider, 'ollama');
  assert.equal(classifyModel('llama3:8b').provider, 'ollama');
  assert.equal(classifyModel('gemma2:9b').provider, 'ollama');
  assert.equal(classifyModel('mistral:latest').provider, 'ollama');
});

test('classifyModel: explicit provider prefix is stripped', () => {
  assert.deepEqual(classifyModel('anthropic,claude-opus-4-7'), { provider: 'anthropic', model: 'claude-opus-4-7' });
  assert.deepEqual(classifyModel('ollama,glm-5.1:cloud'), { provider: 'ollama', model: 'glm-5.1:cloud' });
});

test('classifyModel: empty / unknown → defaults to anthropic', () => {
  assert.equal(classifyModel('').provider, 'anthropic');
  assert.equal(classifyModel(null).provider, 'anthropic');
  assert.equal(classifyModel(undefined).provider, 'anthropic');
});

test('classifyModel: unknown model with colon → ollama (has tag)', () => {
  assert.equal(classifyModel('custom-model:v1').provider, 'ollama');
});

// ── applyGlmRigor ────────────────────────────────────────────────────────
test('applyGlmRigor: adds thinking budget when absent', () => {
  const p = applyGlmRigor({});
  assert.deepEqual(p.thinking, { type: 'enabled', budget_tokens: 32000 });
});

test('applyGlmRigor: fills budget_tokens when thinking.enabled without budget', () => {
  const p = applyGlmRigor({ thinking: { type: 'enabled' } });
  assert.equal(p.thinking.budget_tokens, 32000);
});

test('applyGlmRigor: preserves caller-provided thinking budget', () => {
  const p = applyGlmRigor({ thinking: { type: 'enabled', budget_tokens: 8000 } });
  assert.equal(p.thinking.budget_tokens, 8000);
});

test('applyGlmRigor: sets default temperature when absent', () => {
  const p = applyGlmRigor({});
  assert.equal(p.temperature, 0.3);
});

test('applyGlmRigor: preserves caller-provided temperature (caller wins)', () => {
  const p = applyGlmRigor({ temperature: 1 });
  assert.equal(p.temperature, 1);
  const p2 = applyGlmRigor({ temperature: 0 });
  assert.equal(p2.temperature, 0);
});

test('applyGlmRigor: floors max_tokens at 8192 when smaller / missing', () => {
  assert.equal(applyGlmRigor({}).max_tokens, 8192);
  assert.equal(applyGlmRigor({ max_tokens: 1000 }).max_tokens, 8192);
  assert.equal(applyGlmRigor({ max_tokens: 128000 }).max_tokens, 128000);
});

// ── TokenBucket ──────────────────────────────────────────────────────────
test('TokenBucket: fresh bucket allows capacity consumes then denies', () => {
  const b = new TokenBucket(3, 0); // no refill
  assert.equal(b.tryConsume(), true);
  assert.equal(b.tryConsume(), true);
  assert.equal(b.tryConsume(), true);
  assert.equal(b.tryConsume(), false);
});

test('TokenBucket: refills over time', async () => {
  const b = new TokenBucket(2, 10); // 10 tokens/sec
  assert.equal(b.tryConsume(), true);
  assert.equal(b.tryConsume(), true);
  assert.equal(b.tryConsume(), false);
  await sleep(250); // ~2.5 tokens refilled, capped at 2
  assert.equal(b.tryConsume(), true);
});

test('TokenBucket: tryConsume(n) where n > tokens returns false and does not decrement', () => {
  const b = new TokenBucket(5, 0);
  assert.equal(b.tryConsume(3), true);
  assert.equal(b.tryConsume(5), false); // only 2 left, asking for 5 → denied
  assert.equal(b.tryConsume(2), true); // 2 still available, proving state wasn't decremented on denial
});

// ── CircuitBreaker ───────────────────────────────────────────────────────
test('CircuitBreaker: starts closed and allows attempts', () => {
  const cb = new CircuitBreaker(3, 1000, 'test');
  assert.equal(cb.state, 'closed');
  assert.equal(cb.canAttempt(), true);
});

test('CircuitBreaker: opens after threshold failures', () => {
  const cb = new CircuitBreaker(3, 1000, 'test');
  cb.recordFailure();
  cb.recordFailure();
  assert.equal(cb.state, 'closed');
  cb.recordFailure();
  assert.equal(cb.state, 'open');
  assert.equal(cb.canAttempt(), false);
});

test('CircuitBreaker: half-opens after resetMs elapses', async () => {
  const cb = new CircuitBreaker(1, 50, 'test');
  cb.recordFailure();
  assert.equal(cb.state, 'open');
  assert.equal(cb.canAttempt(), false);
  await sleep(80);
  assert.equal(cb.canAttempt(), true);
  assert.equal(cb.state, 'half-open');
});

test('CircuitBreaker: recordSuccess resets to closed + clears failures', () => {
  const cb = new CircuitBreaker(2, 1000, 'test');
  cb.recordFailure();
  cb.recordFailure();
  assert.equal(cb.state, 'open');
  cb.recordSuccess();
  assert.equal(cb.state, 'closed');
  assert.equal(cb.failures, 0);
});

// ── trackCost ────────────────────────────────────────────────────────────
test('trackCost: unknown model is a no-op', () => {
  const before = JSON.stringify(costState.byModel);
  trackCost('model-does-not-exist', 1000, 1000);
  assert.equal(JSON.stringify(costState.byModel), before);
});

test('trackCost: Claude Opus pricing computes correctly', () => {
  costState.byModel = {}; // reset for isolation
  trackCost('claude-opus-4-7', 1000, 1000);
  // $15/M input + $75/M output = (1000*15 + 1000*75) / 1e6 = 0.090
  assert.ok(Math.abs(costState.byModel['claude-opus-4-7'] - 0.09) < 0.0001);
});

test('trackCost: multiple calls accumulate', () => {
  costState.byModel = {};
  trackCost('claude-opus-4-7', 1000, 1000);
  trackCost('claude-opus-4-7', 2000, 2000);
  // first call 0.09, second call 0.18 → total 0.27
  assert.ok(Math.abs(costState.byModel['claude-opus-4-7'] - 0.27) < 0.0001);
});

// ── PRICING export ───────────────────────────────────────────────────────
test('PRICING: has entries with input/output fields', () => {
  assert.ok(PRICING['claude-opus-4-7']);
  assert.equal(typeof PRICING['claude-opus-4-7'].input, 'number');
  assert.equal(typeof PRICING['claude-opus-4-7'].output, 'number');
  assert.equal(PRICING['glm-5.1:cloud'].input, 0);
  assert.equal(PRICING['glm-5.1:cloud'].output, 0);
});

// ── Auth ─────────────────────────────────────────────────────────────────
test('auth: null token (auth disabled) lets any request through', () => {
  assert.equal(_auth({ headers: {} }, null), true);
  assert.equal(_auth({ headers: { authorization: 'Bearer anything' } }, null), true);
});

test('auth: token set, missing Authorization → denied', () => {
  assert.equal(_auth({ headers: {} }, 'secret-token'), false);
});

test('auth: token set, wrong Bearer token → denied', () => {
  assert.equal(_auth({ headers: { authorization: 'Bearer wrong' } }, 'secret-token'), false);
});

test('auth: token set, correct Bearer token → allowed', () => {
  assert.equal(_auth({ headers: { authorization: 'Bearer secret-token' } }, 'secret-token'), true);
});

test('auth: Claude Max OAuth (sk-ant-*) always passes through even when proxy auth is set', () => {
  assert.equal(_auth({ headers: { authorization: 'Bearer sk-ant-oat01-abc123' } }, 'any-proxy-token'), true);
});
