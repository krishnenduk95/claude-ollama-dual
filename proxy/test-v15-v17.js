#!/usr/bin/env node
// Smoke tests for v1.15/1.16/1.17 token-reduction layers.
// Loads proxy.js source and eval's its helper functions in isolation, so we
// don't start a server. Run: node proxy/test-v15-v17.js
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
const CFG = {
  COMPRESS_CONTEXT: true,
  COMPRESS_KEEP_RECENT_TURNS: 2,
  COMPRESS_MIN_TOOL_RESULT_BYTES: 100,
  SMART_ROUTING: true,
  SMART_ROUTING_HAIKU_MAX_INPUT_CHARS: 4000,
  SMART_ROUTING_SONNET_MAX_INPUT_CHARS: 20000,
};
// Helpers used by injectPromptCaching must be defined in this scope before
// we eval the function, because eval captures the current lexical environment.
const _scanTtls          = eval(`(${extract('_scanTtls')})`);
const _detectGlobalTtl   = eval(`(${extract('_detectGlobalTtl')})`);
const _mkCacheControl    = eval(`(${extract('_mkCacheControl')})`);
const injectPromptCaching = eval(`(${extract('injectPromptCaching')})`);
const compressContext    = eval(`(${extract('compressContext')})`);
const smartRoute         = eval(`(${extract('smartRoute')})`);

let passed = 0, failed = 0;
function t(name, fn) {
  try { fn(); console.log(`  ✓ ${name}`); passed++; }
  catch (e) { console.error(`  ✗ ${name}\n    ${e.message}`); failed++; }
}
function assert(cond, msg) { if (!cond) throw new Error(msg || 'assertion failed'); }
function eq(a, b, msg) {
  if (JSON.stringify(a) !== JSON.stringify(b))
    throw new Error((msg || 'neq') + `\n    want: ${JSON.stringify(b)}\n    got:  ${JSON.stringify(a)}`);
}

console.log('v1.15 compressContext:');
t('compresses large old tool_result', () => {
  const big = 'X'.repeat(500);
  const parsed = {
    messages: [
      { role: 'assistant', content: [{ type: 'tool_use', id: 'tu_1', name: 'Read', input: { file_path: '/foo.ts' } }] },
      { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tu_1', content: big }] },
      { role: 'user', content: 'keep me' },
      { role: 'user', content: 'keep me too' },
    ],
  };
  const { parsed: p2, bytesSaved } = compressContext(parsed);
  assert(bytesSaved >= 500, `bytesSaved=${bytesSaved}`);
  const compressed = p2.messages[1].content[0];
  assert(typeof compressed.content === 'string' && compressed.content.startsWith('[compressed:'),
    `expected stub, got ${JSON.stringify(compressed)}`);
});

t('preserves recent turns verbatim', () => {
  const big = 'Y'.repeat(500);
  const parsed = {
    messages: [
      { role: 'assistant', content: [{ type: 'tool_use', id: 'tu_1', name: 'Read', input: { file_path: '/foo.ts' } }] },
      { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tu_1', content: big }] },
    ],
  };
  const { parsed: p2, bytesSaved } = compressContext(parsed);
  assert(bytesSaved === 0, `should preserve — bytesSaved=${bytesSaved}`);
  assert(p2.messages[1].content[0].content === big, 'recent tool_result was modified');
});

t('dedupes repeated Reads of same file (older stubbed, newer kept when below size threshold)', () => {
  const payload = 'Z'.repeat(50); // below COMPRESS_MIN_TOOL_RESULT_BYTES=100
  const parsed = {
    messages: [
      { role: 'assistant', content: [{ type: 'tool_use', id: 't1', name: 'Read', input: { file_path: '/x.ts' } }] },
      { role: 'user',      content: [{ type: 'tool_result', tool_use_id: 't1', content: payload }] },
      { role: 'assistant', content: [{ type: 'tool_use', id: 't2', name: 'Read', input: { file_path: '/x.ts' } }] },
      { role: 'user',      content: [{ type: 'tool_result', tool_use_id: 't2', content: payload }] },
      { role: 'user', content: 'tail 1' },
      { role: 'user', content: 'tail 2' },
    ],
  };
  const { parsed: p2 } = compressContext(parsed);
  const first  = p2.messages[1].content[0];
  const second = p2.messages[3].content[0];
  assert(typeof first.content === 'string' && first.content.startsWith('[compressed:'),
    `older Read of same file should be stubbed; got ${JSON.stringify(first)}`);
  assert(second.content === payload,
    `newer Read should be preserved; got ${JSON.stringify(second)}`);
});

console.log('\nv1.16 smartRoute:');
t('downgrades tiny opus request to haiku', () => {
  const { model, downgradedFrom } = smartRoute({ messages: [{ role: 'user', content: 'hi' }] }, 'claude-opus-4-7');
  eq(model, 'claude-haiku-4-5-20251001');
  eq(downgradedFrom, 'claude-opus-4-7');
});

t('downgrades medium opus request to sonnet', () => {
  const big = 'a'.repeat(5000);
  const { model, downgradedFrom } = smartRoute({ messages: [{ role: 'user', content: big }] }, 'claude-opus-4-7');
  eq(model, 'claude-sonnet-4-6');
  eq(downgradedFrom, 'claude-opus-4-7');
});

t('preserves opus for large input', () => {
  const big = 'a'.repeat(25000);
  const { model, downgradedFrom } = smartRoute({ messages: [{ role: 'user', content: big }] }, 'claude-opus-4-7');
  eq(model, 'claude-opus-4-7');
  eq(downgradedFrom, null);
});

t('respects explicit thinking=enabled', () => {
  const { model, downgradedFrom } = smartRoute(
    { thinking: { type: 'enabled' }, messages: [{ role: 'user', content: 'hi' }] },
    'claude-opus-4-7'
  );
  eq(model, 'claude-opus-4-7');
  eq(downgradedFrom, null);
});

t('leaves haiku/sonnet alone', () => {
  const r1 = smartRoute({ messages: [{ role: 'user', content: 'hi' }] }, 'claude-haiku-4-5-20251001');
  eq(r1.downgradedFrom, null);
  const r2 = smartRoute({ messages: [{ role: 'user', content: 'hi' }] }, 'claude-sonnet-4-6');
  eq(r2.downgradedFrom, null);
});

console.log('\nv1.17 injectPromptCaching:');
t('marks system string with cache_control', () => {
  const { parsed, breakpoints } = injectPromptCaching({ system: 'You are a helpful assistant.' });
  assert(Array.isArray(parsed.system), 'system should be promoted to array');
  eq(parsed.system[0].cache_control, { type: 'ephemeral' });
  assert(breakpoints >= 1);
});

t('marks last tool with cache_control', () => {
  const { parsed, breakpoints } = injectPromptCaching({
    system: 'sys',
    tools: [{ name: 'Read' }, { name: 'Write' }],
  });
  eq(parsed.tools[1].cache_control, { type: 'ephemeral' });
  assert(!parsed.tools[0].cache_control, 'only last tool should be marked');
  assert(breakpoints >= 2);
});

t('adds message-level breakpoints on long histories', () => {
  const msgs = [];
  for (let i = 0; i < 8; i++) {
    msgs.push({ role: i % 2 ? 'assistant' : 'user', content: `msg ${i}` });
  }
  const { breakpoints } = injectPromptCaching({ system: 'sys', messages: msgs });
  assert(breakpoints >= 3, `expected ≥3 breakpoints, got ${breakpoints}`);
  assert(breakpoints <= 4, `capped at 4`);
});

t('short histories do not add message breakpoints', () => {
  const { breakpoints } = injectPromptCaching({ system: 'sys', messages: [{ role: 'user', content: 'hi' }] });
  eq(breakpoints, 1);
});

// Regression: Anthropic rejects a 5m cache_control block that appears AFTER
// a 1h cache_control block within the same section (tools/system/messages).
// Upstream clients (Claude Code) sometimes pre-mark an earlier system entry
// with ttl='1h'. Our injector must NOT then stamp ttl='5m' on a later entry.
t('preserves 1h ttl when upstream already marked system with 1h', () => {
  const parsed = {
    system: [
      { type: 'text', text: 'stable preamble', cache_control: { type: 'ephemeral', ttl: '1h' } },
      { type: 'text', text: 'dynamic tail' },
    ],
  };
  injectPromptCaching(parsed);
  const tail = parsed.system[parsed.system.length - 1];
  eq(tail.cache_control, { type: 'ephemeral', ttl: '1h' }, 'tail must match 1h to preserve ordering');
});

t('preserves 1h ttl when upstream already marked tools with 1h', () => {
  const parsed = {
    system: 'sys',
    tools: [
      { name: 'A', cache_control: { type: 'ephemeral', ttl: '1h' } },
      { name: 'B' },
    ],
  };
  injectPromptCaching(parsed);
  eq(parsed.tools[1].cache_control, { type: 'ephemeral', ttl: '1h' });
});

t('preserves 1h ttl across messages when upstream pre-marked a message with 1h', () => {
  const msgs = [];
  for (let i = 0; i < 8; i++) {
    msgs.push({ role: i % 2 ? 'assistant' : 'user', content: `msg ${i}` });
  }
  // Pre-mark an early message with 1h.
  msgs[0].content = [{ type: 'text', text: 'msg 0', cache_control: { type: 'ephemeral', ttl: '1h' } }];
  injectPromptCaching({ system: 'sys', messages: msgs });
  // Any cache_control we added must be 1h (not 5m) to avoid ordering violation.
  for (const m of msgs) {
    if (!Array.isArray(m.content)) continue;
    for (const block of m.content) {
      if (!block || !block.cache_control) continue;
      eq(block.cache_control.ttl, '1h', 'every breakpoint must be 1h once upstream used 1h');
    }
  }
});

t('defaults to 5m (no ttl) when no pre-existing 1h breakpoint', () => {
  const parsed = {
    system: [
      { type: 'text', text: 'stable preamble' },
      { type: 'text', text: 'dynamic tail' },
    ],
  };
  injectPromptCaching(parsed);
  const tail = parsed.system[parsed.system.length - 1];
  eq(tail.cache_control, { type: 'ephemeral' }, 'no pre-existing 1h → default ephemeral (5m)');
});

// v1.17.2 regression: ordering constraint is GLOBAL (tools → system →
// messages). A 1h anywhere in the request means every breakpoint we add
// must also be 1h, not just breakpoints in the same section.
t('promotes tool breakpoint to 1h when system has a pre-existing 1h', () => {
  const parsed = {
    tools: [{ name: 'Read' }, { name: 'Write' }],
    system: [
      { type: 'text', text: 'stable', cache_control: { type: 'ephemeral', ttl: '1h' } },
    ],
  };
  injectPromptCaching(parsed);
  // Tool breakpoint must be 1h — otherwise tools=5m followed by system=1h violates order.
  eq(parsed.tools[1].cache_control, { type: 'ephemeral', ttl: '1h' },
    'tools breakpoint must match the 1h that exists in system');
});

t('promotes tool breakpoint to 1h when a message has a pre-existing 1h', () => {
  const msgs = [];
  for (let i = 0; i < 8; i++) {
    msgs.push({ role: i % 2 ? 'assistant' : 'user', content: `msg ${i}` });
  }
  msgs[1].content = [{ type: 'text', text: 'msg 1', cache_control: { type: 'ephemeral', ttl: '1h' } }];
  const parsed = { tools: [{ name: 'Read' }], system: 'sys', messages: msgs };
  injectPromptCaching(parsed);
  eq(parsed.tools[0].cache_control, { type: 'ephemeral', ttl: '1h' },
    'tools breakpoint must match a 1h that lives deep in messages');
  // System (promoted from string) must also be 1h, not 5m.
  eq(parsed.system[0].cache_control, { type: 'ephemeral', ttl: '1h' },
    'promoted system block must match the 1h elsewhere in the payload');
});

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
