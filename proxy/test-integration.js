// Integration tests for the proxy — fixture-driven regression suite for
// the four real bug categories that hit production this week (2026-04-25):
//
//   B1. Cache-control TTL ordering (in-section)        — v1.17.1
//   B2. Cache-control TTL ordering (across sections)   — v1.17.2
//   B3. >4 cache_control breakpoints in a single req   — v1.17.3
//   B4. max_tokens exceeds Ollama model ceiling        — v1.18.0
//
// Each fixture is a real-shaped payload (constructed minimally to mimic
// what Claude Code actually sends). We run the full inject pipeline on
// it and assert the result satisfies Anthropic's published constraints.
//
// These run as a sibling to test-v15-v17.js. The unit tests there cover
// each function in isolation; this file covers full payload pipelines.

'use strict';

const fs = require('fs');
const path = require('path');

const src = fs.readFileSync(path.join(__dirname, 'proxy.js'), 'utf8');

function extract(name) {
  const re = new RegExp(`function ${name}\\s*\\([^]*?\\n\\}`, 'm');
  const m = src.match(re);
  if (!m) throw new Error(`could not extract ${name}`);
  return m[0];
}
function extractConstBlock(name) {
  const re = new RegExp(`const ${name}\\s*=\\s*([^;]*?);`, 'm');
  const m = src.match(re);
  if (!m) throw new Error(`could not extract const ${name}`);
  return m[1];
}

// Mirror unit-test extraction so the integration tests share the same
// loaded view of the source.
const CFG = {
  COMPRESS_CONTEXT: true,
  COMPRESS_KEEP_RECENT_TURNS: 10,
  COMPRESS_MIN_TOOL_RESULT_BYTES: 2000,
  GLM_THINKING_BUDGET: 32000,
  GLM_TEMPERATURE: 0.3,
  GLM_MAX_TOKENS_FLOOR: 8192,
};
const _scanTtls          = eval(`(${extract('_scanTtls')})`);
const _detectGlobalTtl   = eval(`(${extract('_detectGlobalTtl')})`);
const _mkCacheControl    = eval(`(${extract('_mkCacheControl')})`);
const _countExistingBreakpoints = eval(`(${extract('_countExistingBreakpoints')})`);
const injectPromptCaching = eval(`(${extract('injectPromptCaching')})`);
const compressContext    = eval(`(${extract('compressContext')})`);
const MODEL_MAX_OUTPUT      = eval(`(${extractConstBlock('MODEL_MAX_OUTPUT')})`);
const SAFE_MAX_OUTPUT_FALLBACK = eval(`(${extractConstBlock('SAFE_MAX_OUTPUT_FALLBACK')})`);
const _ceilingFor           = eval(`(${extract('_ceilingFor')})`);
const applyGlmRigor         = eval(`(${extract('applyGlmRigor')})`);

let passed = 0, failed = 0;
function t(name, fn) {
  try { fn(); console.log('  ✓ ' + name); passed++; }
  catch (e) { console.log('  ✗ ' + name + '\n    ' + e.message); failed++; }
}
function assert(cond, msg) { if (!cond) throw new Error(msg || 'assertion failed'); }

// Walk the request and produce the flattened cache_control sequence in
// Anthropic's canonical ingestion order: tools → system → messages.
// Each entry is { ttl, location } where ttl is '1h' or '5m'.
function flattenBreakpoints(parsed) {
  const out = [];
  const visit = (arr, loc) => {
    if (!Array.isArray(arr)) return;
    for (let i = 0; i < arr.length; i++) {
      const item = arr[i];
      if (!item || typeof item !== 'object') continue;
      if (item.cache_control && typeof item.cache_control === 'object') {
        const ttl = item.cache_control.ttl === '1h' ? '1h' : '5m';
        out.push({ ttl, location: `${loc}[${i}]` });
      }
      if (Array.isArray(item.content)) visit(item.content, `${loc}[${i}].content`);
    }
  };
  visit(parsed.tools, 'tools');
  visit(parsed.system, 'system');
  visit(parsed.messages, 'messages');
  return out;
}

// Anthropic enforces: in the flattened sequence, all '1h' blocks come
// before all '5m' blocks. Encoded as: once we see a '5m', we must never
// see another '1h'.
function assertOrderingValid(parsed) {
  const seq = flattenBreakpoints(parsed);
  let saw5m = false;
  for (const entry of seq) {
    if (entry.ttl === '5m') saw5m = true;
    if (saw5m && entry.ttl === '1h') {
      throw new Error(`TTL ordering violation: 1h block at ${entry.location} comes after a 5m block. Sequence: ${seq.map(e=>`${e.ttl}@${e.location}`).join(', ')}`);
    }
  }
}
function assertCapValid(parsed) {
  const total = _countExistingBreakpoints(parsed);
  if (total > 4) {
    throw new Error(`Total cache_control breakpoints exceeds Anthropic cap of 4: got ${total}`);
  }
}

// -------- Fixtures --------

// F1: Realistic Claude Code request: long system prompt as string,
// plenty of messages, many tools — what Opus sees on a normal turn.
function fixtureBasicAnthropicTurn() {
  return {
    model: 'claude-opus-4-7',
    max_tokens: 64000,
    thinking: { type: 'enabled', budget_tokens: 32000 },
    system: 'You are Claude, an AI assistant. ' + 'A'.repeat(200),
    tools: [
      { name: 'Read', description: 'read a file' },
      { name: 'Write', description: 'write a file' },
      { name: 'Bash', description: 'run shell' },
    ],
    messages: [
      { role: 'user', content: 'first turn user message' },
      { role: 'assistant', content: 'first turn assistant reply' },
      { role: 'user', content: 'second turn user' },
      { role: 'assistant', content: 'second turn assistant' },
      { role: 'user', content: 'third turn — small request' },
    ],
  };
}

// F2: Claude Code already pre-marked an early system block with 1h
// (this is the production failure pattern — caused 400 in v1.17.0).
function fixtureUpstreamPreMarkedSystem1h() {
  return {
    model: 'claude-opus-4-7',
    max_tokens: 64000,
    system: [
      { type: 'text', text: 'STABLE PREAMBLE WITH 1H', cache_control: { type: 'ephemeral', ttl: '1h' } },
      { type: 'text', text: 'dynamic per-turn payload, much shorter' },
    ],
    tools: [{ name: 'Read' }, { name: 'Write' }],
    messages: [
      { role: 'user', content: 'short' },
      { role: 'assistant', content: 'short' },
      { role: 'user', content: 'short' },
      { role: 'assistant', content: 'short' },
      { role: 'user', content: 'short' },
    ],
  };
}

// F3: Upstream pre-marked a deep message block with 1h. Without the
// cross-section global scan (v1.17.2), the proxy would have stamped a
// default 5m on tools[last], creating tools=5m → system=anything →
// messages[1h], a global ordering violation.
function fixtureUpstreamPreMarkedMessage1h() {
  const msgs = [];
  for (let i = 0; i < 8; i++) msgs.push({ role: i % 2 ? 'assistant' : 'user', content: `m${i}` });
  msgs[1].content = [{ type: 'text', text: 'deep stable', cache_control: { type: 'ephemeral', ttl: '1h' } }];
  return {
    model: 'claude-opus-4-7',
    max_tokens: 64000,
    system: 'sys',
    tools: [{ name: 'Read' }, { name: 'Bash' }],
    messages: msgs,
  };
}

// F4: Upstream already placed 4 breakpoints (the cap). v1.17.3 must
// add 0 more. Without the cap fix, we'd push the total to 6+.
function fixtureUpstreamAlreadyAt4Cap() {
  const msgs = [];
  for (let i = 0; i < 10; i++) msgs.push({ role: i % 2 ? 'assistant' : 'user', content: `m${i}` });
  msgs[1].content = [{ type: 'text', text: 'm1', cache_control: { type: 'ephemeral' } }];
  msgs[3].content = [{ type: 'text', text: 'm3', cache_control: { type: 'ephemeral' } }];
  msgs[5].content = [{ type: 'text', text: 'm5', cache_control: { type: 'ephemeral' } }];
  return {
    model: 'claude-opus-4-7',
    max_tokens: 64000,
    tools: [{ name: 'Read', cache_control: { type: 'ephemeral' } }],
    system: 'sys',
    messages: msgs,
  };
}

// F5: GLM dispatch — Claude Code sends max_tokens=128000, model is
// deepseek-v4-flash:cloud (cap 65536). Without v1.18.0, Ollama rejects.
function fixtureGlmDispatchOversize() {
  return {
    model: 'deepseek-v4-flash:cloud',
    max_tokens: 128000,
    thinking: { type: 'enabled', budget_tokens: 64000 },
    system: 'You are a worker subagent.',
    messages: [{ role: 'user', content: 'do the thing' }],
  };
}

// F6: GLM dispatch with no thinking and a small max_tokens. We should
// inject thinking and apply the floor — but never raise above ceiling.
function fixtureGlmDispatchSmallNoThinking() {
  return {
    model: 'glm-5.1:cloud',
    max_tokens: 4096,
    system: 'sys',
    messages: [{ role: 'user', content: 'small task' }],
  };
}

// -------- Pipeline runners --------

function runAnthropicPipeline(parsed) {
  // Mirrors handle()'s anthropic branch: compress → injectPromptCaching.
  const c = compressContext(parsed);
  parsed = c.parsed;
  const ic = injectPromptCaching(parsed);
  return { parsed: ic.parsed, breakpoints: ic.breakpoints };
}
function runGlmPipeline(parsed) {
  return applyGlmRigor(parsed);
}

// -------- Tests --------

console.log('Integration tests — full-payload regression for proxy bugs B1–B4\n');

console.log('F1 baseline anthropic turn:');
t('produces a valid request that satisfies cap and ordering', () => {
  const p = runAnthropicPipeline(fixtureBasicAnthropicTurn());
  assertCapValid(p.parsed);
  assertOrderingValid(p.parsed);
  assert(p.breakpoints >= 1, 'expected at least one cache breakpoint to be added');
});

console.log('F2 upstream pre-marked system[0] with 1h (regression for B1):');
t('does not produce a 5m breakpoint after the 1h block in the same section', () => {
  const p = runAnthropicPipeline(fixtureUpstreamPreMarkedSystem1h());
  assertCapValid(p.parsed);
  assertOrderingValid(p.parsed);
});
t('preserves the upstream 1h marker (we do not overwrite it)', () => {
  const p = runAnthropicPipeline(fixtureUpstreamPreMarkedSystem1h());
  assert(p.parsed.system[0].cache_control.ttl === '1h',
    'upstream 1h must remain after pipeline');
});

console.log('F3 upstream pre-marked deep message with 1h (regression for B2):');
t('matches global TTL — tools breakpoint promoted to 1h', () => {
  const p = runAnthropicPipeline(fixtureUpstreamPreMarkedMessage1h());
  assertCapValid(p.parsed);
  assertOrderingValid(p.parsed);
  // Whatever we added to tools[last] must be 1h, not 5m, otherwise the
  // global sequence would put 5m before the messages-side 1h.
  const lastTool = p.parsed.tools[p.parsed.tools.length - 1];
  if (lastTool.cache_control) {
    assert(lastTool.cache_control.ttl === '1h',
      `tool breakpoint must be 1h, got ${JSON.stringify(lastTool.cache_control)}`);
  }
});

console.log('F4 upstream already at 4-breakpoint cap (regression for B3):');
t('adds zero new breakpoints when budget is exhausted', () => {
  const p = runAnthropicPipeline(fixtureUpstreamAlreadyAt4Cap());
  assertCapValid(p.parsed);
  assertOrderingValid(p.parsed);
  assert(p.breakpoints === 0, `must add 0 breakpoints, added ${p.breakpoints}`);
});

console.log('F5 GLM dispatch with oversize max_tokens (regression for B4):');
t('clamps max_tokens to deepseek-v4-flash ceiling (65536)', () => {
  const fixture = fixtureGlmDispatchOversize();
  const p = runGlmPipeline(fixture);
  assert(p.max_tokens === 65536,
    `max_tokens should be 65536 for deepseek-v4-flash:cloud, got ${p.max_tokens}`);
});
t('shrinks thinking.budget_tokens to fit clamped max_tokens', () => {
  const fixture = fixtureGlmDispatchOversize();
  const p = runGlmPipeline(fixture);
  assert(p.thinking.budget_tokens < p.max_tokens,
    `thinking.budget_tokens (${p.thinking.budget_tokens}) must be < max_tokens (${p.max_tokens})`);
  assert(p.thinking.budget_tokens >= 1024,
    `thinking.budget_tokens must keep ≥1024 (output headroom), got ${p.thinking.budget_tokens}`);
});

console.log('F6 GLM dispatch small + no thinking (sanity):');
t('applies floor and injects thinking for small GLM requests', () => {
  const fixture = fixtureGlmDispatchSmallNoThinking();
  const p = runGlmPipeline(fixture);
  assert(p.max_tokens >= 8192, `floor must apply, got ${p.max_tokens}`);
  assert(p.thinking && p.thinking.type === 'enabled',
    'thinking should be injected and enabled');
  // applyGlmRigor injects 32k thinking, then shrinks it if it exceeds
  // max_tokens (here 8192 floor → thinking budget gets clamped down).
  // We just need a positive thinking budget that leaves output headroom.
  assert(p.thinking.budget_tokens > 0 && p.thinking.budget_tokens < p.max_tokens,
    `thinking budget (${p.thinking.budget_tokens}) must be 0<x<max_tokens(${p.max_tokens})`);
});

console.log('\nGlobal sanity (every fixture):');
const ALL_ANTHROPIC = [
  ['F1', fixtureBasicAnthropicTurn],
  ['F2', fixtureUpstreamPreMarkedSystem1h],
  ['F3', fixtureUpstreamPreMarkedMessage1h],
  ['F4', fixtureUpstreamAlreadyAt4Cap],
];
for (const [label, mkFixture] of ALL_ANTHROPIC) {
  t(`${label} — cap ≤4 and ordering valid after pipeline`, () => {
    const p = runAnthropicPipeline(mkFixture());
    assertCapValid(p.parsed);
    assertOrderingValid(p.parsed);
  });
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
