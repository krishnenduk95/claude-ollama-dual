#!/usr/bin/env node
// claude-dual proxy — routes between Claude Max (via OAuth passthrough) and Ollama (for GLM)
//
// On GLM routes, injects Opus-grade rigor parameters if the caller didn't specify them:
//   - thinking: extended reasoning budget (32k tokens)
//   - temperature: 0.3 for consistent, careful reasoning
// These are *defaults* — an explicit value from Claude Code wins.

const http = require('http');
const https = require('https');

const LISTEN_HOST = '127.0.0.1';
const LISTEN_PORT = 3456;
const ANTHROPIC_HOST = 'api.anthropic.com';
const OLLAMA_HOST = '127.0.0.1';
const OLLAMA_PORT = 11434;

const GLM_DEFAULT_THINKING_BUDGET = 32000;
const GLM_DEFAULT_TEMPERATURE = 0.3;
const GLM_DEFAULT_MAX_TOKENS_FLOOR = 8192;

const log = (...args) => console.log(new Date().toISOString(), ...args);

const applyGlmRigor = (parsed) => {
  // extended thinking — only set if caller didn't
  if (!parsed.thinking) {
    parsed.thinking = { type: 'enabled', budget_tokens: GLM_DEFAULT_THINKING_BUDGET };
  } else if (parsed.thinking.type === 'enabled' && !parsed.thinking.budget_tokens) {
    parsed.thinking.budget_tokens = GLM_DEFAULT_THINKING_BUDGET;
  }
  // temperature default
  if (parsed.temperature === undefined || parsed.temperature === null) {
    parsed.temperature = GLM_DEFAULT_TEMPERATURE;
  }
  // ensure enough headroom for thinking + output
  if (!parsed.max_tokens || parsed.max_tokens < GLM_DEFAULT_MAX_TOKENS_FLOOR) {
    parsed.max_tokens = Math.max(parsed.max_tokens || 0, GLM_DEFAULT_MAX_TOKENS_FLOOR);
  }
  return parsed;
};

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    let parsed = {};
    try {
      parsed = JSON.parse(body);
    } catch (_) {}

    const model = (parsed.model || '').toString();
    const stripped = model.startsWith('ollama,')
      ? model.slice('ollama,'.length)
      : model.startsWith('anthropic,')
      ? model.slice('anthropic,'.length)
      : model;

    const isClaude = /^claude-/.test(stripped);
    const isOllama = /^(glm-|gemma|qwen|llama|mistral)/i.test(stripped) || stripped.includes(':');

    let targetOpts;
    const headers = { ...req.headers };
    delete headers.host;
    delete headers['content-length'];

    if (isClaude) {
      parsed.model = stripped;
      targetOpts = {
        protocol: 'https:',
        hostname: ANTHROPIC_HOST,
        port: 443,
        path: req.url,
        method: req.method,
        headers: { ...headers, host: ANTHROPIC_HOST },
      };
      log(
        `→ ANTHROPIC ${req.url} model=${stripped} auth=${(
          headers.authorization ||
          headers['x-api-key'] ||
          ''
        ).slice(0, 20)}...`
      );
    } else if (isOllama) {
      parsed.model = stripped;
      parsed = applyGlmRigor(parsed);
      targetOpts = {
        protocol: 'http:',
        hostname: OLLAMA_HOST,
        port: OLLAMA_PORT,
        path: '/v1/messages',
        method: 'POST',
        headers: {
          ...headers,
          host: `${OLLAMA_HOST}:${OLLAMA_PORT}`,
          authorization: 'Bearer ollama',
          'x-api-key': 'ollama',
        },
      };
      log(
        `→ OLLAMA   ${req.url} model=${stripped} thinking.budget=${parsed.thinking?.budget_tokens} temp=${parsed.temperature} max_tokens=${parsed.max_tokens}`
      );
    } else {
      log(`? UNKNOWN  ${req.url} model=${stripped} — defaulting to Anthropic`);
      parsed.model = stripped;
      targetOpts = {
        protocol: 'https:',
        hostname: ANTHROPIC_HOST,
        port: 443,
        path: req.url,
        method: req.method,
        headers: { ...headers, host: ANTHROPIC_HOST },
      };
    }

    const outBody = Object.keys(parsed).length ? JSON.stringify(parsed) : body;
    targetOpts.headers['content-length'] = Buffer.byteLength(outBody).toString();

    const lib = targetOpts.protocol === 'https:' ? https : http;
    const pReq = lib.request(targetOpts, (pRes) => {
      res.writeHead(pRes.statusCode, pRes.headers);
      pRes.pipe(res);
    });
    pReq.on('error', (err) => {
      log(`✗ ERROR ${err.message}`);
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({ error: { type: 'proxy_error', message: err.message } })
      );
    });
    pReq.write(outBody);
    pReq.end();
  });
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  log(`claude-dual proxy listening on http://${LISTEN_HOST}:${LISTEN_PORT}`);
  log(`  claude-* → https://${ANTHROPIC_HOST} (OAuth forwarded)`);
  log(
    `  glm-*/ollama → http://${OLLAMA_HOST}:${OLLAMA_PORT} (thinking=${GLM_DEFAULT_THINKING_BUDGET} tokens, temp=${GLM_DEFAULT_TEMPERATURE})`
  );
});
