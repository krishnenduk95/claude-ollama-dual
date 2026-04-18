#!/usr/bin/env node
/*
 * claude-dual proxy v2 — enterprise-grade routing for Claude Opus + GLM via Ollama
 *
 * Features:
 *   - OAuth-preserving routing (Anthropic vs Ollama by model name)
 *   - GLM rigor injection (thinking budget, temperature, max_tokens floor)
 *   - Health endpoints: /health, /livez, /readyz, /metrics (Prometheus), /cost
 *   - Structured JSON logging via pino (request IDs, trace correlation)
 *   - Retry with exponential backoff on network + 5xx failures
 *   - Per-provider circuit breaker (opens after N failures, self-heals)
 *   - Per-provider token-bucket rate limiting (protects your quota)
 *   - Request size limit (rejects oversized payloads with 413)
 *   - Optional Bearer token auth (env PROXY_AUTH_TOKEN)
 *   - Graceful shutdown (SIGTERM drains in-flight requests)
 *   - Prometheus metrics (requests, duration, circuit state, cost)
 *   - Rough cost tracking per model per day with 80% / 100% alerts
 *   - Audit trail (structured JSON log of every dispatch)
 *   - Cross-platform (works on macOS, Linux, Windows with Node 18+)
 *
 * Config via env vars (all optional, sensible defaults):
 *   CLAUDE_DUAL_HOST            listen host                       (127.0.0.1)
 *   CLAUDE_DUAL_PORT            listen port                       (3456)
 *   ANTHROPIC_HOST              Anthropic API host                (api.anthropic.com)
 *   OLLAMA_HOST                 Ollama host                       (127.0.0.1)
 *   OLLAMA_PORT                 Ollama port                       (11434)
 *   GLM_THINKING_BUDGET         thinking tokens injected for GLM  (32000)
 *   GLM_TEMPERATURE             default temp for GLM              (0.3)
 *   GLM_MAX_TOKENS_FLOOR        min max_tokens for GLM            (8192)
 *   RATE_LIMIT_RPM              requests-per-minute per provider  (200)
 *   MAX_REQUEST_BYTES           max body size                     (10485760 = 10MB)
 *   CIRCUIT_THRESHOLD           failures before circuit opens     (5)
 *   CIRCUIT_RESET_MS            ms before half-open retry         (30000)
 *   RETRY_MAX                   max retry attempts on failure     (3)
 *   RETRY_BASE_MS               backoff base                      (500)
 *   PROXY_AUTH_TOKEN            if set, require Bearer <token>    (unset = no auth)
 *   COST_DAILY_LIMIT_USD        daily spend alert ceiling         (100)
 *   LOG_LEVEL                   pino log level                    (info)
 *   LOG_FILE                    if set, log to file w/ rotation   (unset = stdout)
 *   AUDIT_FILE                  dispatch audit trail path         (~/.claude-dual/audit.jsonl)
 */

'use strict';

const http = require('http');
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');

// ── Optional deps (graceful fallback if missing) ─────────────────────────
let pino, promClient;
try { pino = require('pino'); } catch {
  pino = (opts) => ({
    info: (obj) => console.log(JSON.stringify({ level: 'info', ts: new Date().toISOString(), ...obj })),
    warn: (obj) => console.warn(JSON.stringify({ level: 'warn', ts: new Date().toISOString(), ...obj })),
    error: (obj) => console.error(JSON.stringify({ level: 'error', ts: new Date().toISOString(), ...obj })),
    debug: () => {},
    child: () => pino(opts),
  });
  pino.stdTimeFunctions = { isoTime: () => `,"time":"${new Date().toISOString()}"` };
}
try { promClient = require('prom-client'); } catch { promClient = null; }

// ── Config ───────────────────────────────────────────────────────────────
const CFG = {
  LISTEN_HOST: process.env.CLAUDE_DUAL_HOST || '127.0.0.1',
  LISTEN_PORT: parseInt(process.env.CLAUDE_DUAL_PORT || '3456', 10),
  ANTHROPIC_HOST: process.env.ANTHROPIC_HOST || 'api.anthropic.com',
  OLLAMA_HOST: process.env.OLLAMA_HOST || '127.0.0.1',
  OLLAMA_PORT: parseInt(process.env.OLLAMA_PORT || '11434', 10),
  GLM_THINKING_BUDGET: parseInt(process.env.GLM_THINKING_BUDGET || '32000', 10),
  GLM_TEMPERATURE: parseFloat(process.env.GLM_TEMPERATURE || '0.3'),
  GLM_MAX_TOKENS_FLOOR: parseInt(process.env.GLM_MAX_TOKENS_FLOOR || '8192', 10),
  RATE_LIMIT_RPM: parseInt(process.env.RATE_LIMIT_RPM || '200', 10),
  MAX_REQUEST_BYTES: parseInt(process.env.MAX_REQUEST_BYTES || `${10 * 1024 * 1024}`, 10),
  CIRCUIT_THRESHOLD: parseInt(process.env.CIRCUIT_THRESHOLD || '5', 10),
  CIRCUIT_RESET_MS: parseInt(process.env.CIRCUIT_RESET_MS || '30000', 10),
  RETRY_MAX: parseInt(process.env.RETRY_MAX || '3', 10),
  RETRY_BASE_MS: parseInt(process.env.RETRY_BASE_MS || '500', 10),
  PROXY_AUTH_TOKEN: process.env.PROXY_AUTH_TOKEN || null,
  COST_DAILY_LIMIT_USD: parseFloat(process.env.COST_DAILY_LIMIT_USD || '100'),
  LOG_LEVEL: process.env.LOG_LEVEL || 'info',
  LOG_FILE: process.env.LOG_FILE || null,
  AUDIT_FILE: process.env.AUDIT_FILE || path.join(os.homedir(), '.claude-dual', 'audit.jsonl'),
};

// ── Logger ───────────────────────────────────────────────────────────────
const logger = pino({
  level: CFG.LOG_LEVEL,
  base: { service: 'claude-dual-proxy', pid: process.pid },
  timestamp: pino.stdTimeFunctions ? pino.stdTimeFunctions.isoTime : undefined,
  ...(CFG.LOG_FILE ? { transport: { target: 'pino/file', options: { destination: CFG.LOG_FILE, mkdir: true } } } : {}),
});

// ── Metrics (optional) ───────────────────────────────────────────────────
let metrics = null;
if (promClient) {
  const register = new promClient.Registry();
  promClient.collectDefaultMetrics({ register });
  metrics = {
    register,
    requestsTotal: new promClient.Counter({
      name: 'claude_dual_requests_total', help: 'Total proxy requests',
      labelNames: ['provider', 'model', 'status_class'], registers: [register],
    }),
    requestDuration: new promClient.Histogram({
      name: 'claude_dual_request_duration_seconds', help: 'Request duration',
      labelNames: ['provider', 'model'],
      buckets: [0.1, 0.5, 1, 2, 5, 10, 30, 60, 120, 300],
      registers: [register],
    }),
    circuitState: new promClient.Gauge({
      name: 'claude_dual_circuit_state', help: 'Circuit state (0=closed, 1=open, 2=half-open)',
      labelNames: ['provider'], registers: [register],
    }),
    retriesTotal: new promClient.Counter({
      name: 'claude_dual_retries_total', help: 'Retry attempts',
      labelNames: ['provider'], registers: [register],
    }),
    rateLimitRejected: new promClient.Counter({
      name: 'claude_dual_rate_limit_rejected_total', help: 'Requests rejected by rate limiter',
      labelNames: ['provider'], registers: [register],
    }),
    costUsd: new promClient.Gauge({
      name: 'claude_dual_cost_usd_today', help: 'Estimated cost today in USD',
      labelNames: ['model'], registers: [register],
    }),
    inflight: new promClient.Gauge({
      name: 'claude_dual_inflight_requests', help: 'In-flight requests',
      registers: [register],
    }),
  };
}

// ── Rate limiter (token bucket per provider) ─────────────────────────────
class TokenBucket {
  constructor(capacity, refillPerSec) {
    this.capacity = capacity;
    this.tokens = capacity;
    this.refillPerSec = refillPerSec;
    this.last = Date.now();
  }
  tryConsume(n = 1) {
    const now = Date.now();
    this.tokens = Math.min(this.capacity, this.tokens + ((now - this.last) / 1000) * this.refillPerSec);
    this.last = now;
    if (this.tokens >= n) { this.tokens -= n; return true; }
    return false;
  }
}
const limiters = {
  anthropic: new TokenBucket(CFG.RATE_LIMIT_RPM, CFG.RATE_LIMIT_RPM / 60),
  ollama: new TokenBucket(CFG.RATE_LIMIT_RPM, CFG.RATE_LIMIT_RPM / 60),
};

// ── Circuit breaker per provider ─────────────────────────────────────────
class CircuitBreaker {
  constructor(threshold, resetMs, name) {
    this.state = 'closed';
    this.failures = 0;
    this.threshold = threshold;
    this.resetMs = resetMs;
    this.lastFailure = 0;
    this.name = name;
  }
  canAttempt() {
    if (this.state === 'closed') return true;
    if (this.state === 'open' && Date.now() - this.lastFailure > this.resetMs) {
      this.state = 'half-open';
      this._updateMetric();
      return true;
    }
    return this.state === 'half-open';
  }
  recordSuccess() {
    if (this.state !== 'closed') logger.info({ event: 'circuit_close', provider: this.name });
    this.failures = 0;
    this.state = 'closed';
    this._updateMetric();
  }
  recordFailure() {
    this.failures++;
    this.lastFailure = Date.now();
    if (this.failures >= this.threshold && this.state !== 'open') {
      this.state = 'open';
      logger.warn({ event: 'circuit_open', provider: this.name, failures: this.failures });
    }
    this._updateMetric();
  }
  _updateMetric() {
    if (metrics) metrics.circuitState.set({ provider: this.name }, { closed: 0, open: 1, 'half-open': 2 }[this.state]);
  }
}
const breakers = {
  anthropic: new CircuitBreaker(CFG.CIRCUIT_THRESHOLD, CFG.CIRCUIT_RESET_MS, 'anthropic'),
  ollama: new CircuitBreaker(CFG.CIRCUIT_THRESHOLD, CFG.CIRCUIT_RESET_MS, 'ollama'),
};

// ── Cost tracking (rough, based on published pricing) ────────────────────
const PRICING = {
  'claude-opus-4-7': { input: 15.00, output: 75.00 },
  'claude-opus-4-6': { input: 15.00, output: 75.00 },
  'claude-sonnet-4-6': { input: 3.00, output: 15.00 },
  'claude-haiku-4-5-20251001': { input: 0.80, output: 4.00 },
  'glm-5.1:cloud': { input: 0.00, output: 0.00 },
};
const costState = { date: isoDate(), byModel: {}, alerted80: false, alerted100: false };
function isoDate() { return new Date().toISOString().slice(0, 10); }
function trackCost(model, inputTokens, outputTokens) {
  const today = isoDate();
  if (costState.date !== today) {
    costState.date = today;
    costState.byModel = {};
    costState.alerted80 = false;
    costState.alerted100 = false;
  }
  const p = PRICING[model];
  if (!p) return;
  const cost = (inputTokens * p.input + outputTokens * p.output) / 1e6;
  costState.byModel[model] = (costState.byModel[model] || 0) + cost;
  if (metrics) metrics.costUsd.set({ model }, costState.byModel[model]);
  const total = Object.values(costState.byModel).reduce((a, b) => a + b, 0);
  if (total > CFG.COST_DAILY_LIMIT_USD && !costState.alerted100) {
    logger.error({ event: 'cost_limit_exceeded', total, limit: CFG.COST_DAILY_LIMIT_USD });
    costState.alerted100 = true;
  } else if (total > CFG.COST_DAILY_LIMIT_USD * 0.8 && !costState.alerted80) {
    logger.warn({ event: 'cost_80pct_threshold', total, limit: CFG.COST_DAILY_LIMIT_USD });
    costState.alerted80 = true;
  }
}

// ── Audit trail ──────────────────────────────────────────────────────────
let auditStream = null;
function initAudit() {
  try {
    fs.mkdirSync(path.dirname(CFG.AUDIT_FILE), { recursive: true });
    auditStream = fs.createWriteStream(CFG.AUDIT_FILE, { flags: 'a' });
  } catch (err) {
    logger.warn({ event: 'audit_init_failed', err: err.message });
  }
}
function auditLog(entry) {
  if (!auditStream) return;
  try { auditStream.write(JSON.stringify({ ts: new Date().toISOString(), ...entry }) + '\n'); }
  catch {}
}

// ── Prompt caching injection for Anthropic ───────────────────────────────
function injectPromptCaching(parsed) {
  if (typeof parsed.system === 'string' && parsed.system.length > 0) {
    parsed.system = [{ type: 'text', text: parsed.system, cache_control: { type: 'ephemeral' } }];
  } else if (Array.isArray(parsed.system) && parsed.system.length > 0) {
    const last = parsed.system[parsed.system.length - 1];
    if (!last.cache_control) last.cache_control = { type: 'ephemeral' };
  }
  return parsed;
}

// ── Rigor injection for GLM ──────────────────────────────────────────────
function applyGlmRigor(parsed) {
  if (!parsed.thinking) {
    parsed.thinking = { type: 'enabled', budget_tokens: CFG.GLM_THINKING_BUDGET };
  } else if (parsed.thinking.type === 'enabled' && !parsed.thinking.budget_tokens) {
    parsed.thinking.budget_tokens = CFG.GLM_THINKING_BUDGET;
  }
  if (parsed.temperature === undefined || parsed.temperature === null) {
    parsed.temperature = CFG.GLM_TEMPERATURE;
  }
  if (!parsed.max_tokens || parsed.max_tokens < CFG.GLM_MAX_TOKENS_FLOOR) {
    parsed.max_tokens = Math.max(parsed.max_tokens || 0, CFG.GLM_MAX_TOKENS_FLOOR);
  }
  return parsed;
}

// ── Routing classifier ───────────────────────────────────────────────────
function classifyModel(rawModel) {
  const s = String(rawModel || '');
  const stripped = s.startsWith('ollama,') ? s.slice(7) :
                   s.startsWith('anthropic,') ? s.slice(10) : s;
  if (/^claude-/.test(stripped)) return { provider: 'anthropic', model: stripped };
  if (/^(glm-|gemma|qwen|llama|mistral|phi|deepseek)/i.test(stripped) || (stripped && stripped.includes(':'))) {
    return { provider: 'ollama', model: stripped };
  }
  return { provider: 'anthropic', model: stripped };
}

// ── Auth ─────────────────────────────────────────────────────────────────
function checkAuth(req) {
  if (!CFG.PROXY_AUTH_TOKEN) return true;
  const auth = req.headers.authorization || '';
  if (auth.startsWith('Bearer sk-ant-')) return true; // Claude Max OAuth passes through
  const m = auth.match(/^Bearer\s+(.+)$/);
  if (!m) return false;
  try {
    const tokenBuf = Buffer.from(m[1]);
    const cfgBuf = Buffer.from(CFG.PROXY_AUTH_TOKEN);
    if (tokenBuf.length !== cfgBuf.length) return false;
    return crypto.timingSafeEqual(tokenBuf, cfgBuf);
  } catch { return false; }
}

// ── Health / metrics endpoints ───────────────────────────────────────────
function handleInternalEndpoint(req, res) {
  if (req.method !== 'GET') return false;
  const url = req.url.split('?')[0];
  if (url === '/health' || url === '/livez') {
    send(res, 200, { status: 'ok', uptime_sec: Math.floor(process.uptime()) });
    return true;
  }
  if (url === '/readyz') {
    const anyOpen = breakers.anthropic.state !== 'open' || breakers.ollama.state !== 'open';
    send(res, anyOpen ? 200 : 503, {
      status: anyOpen ? 'ready' : 'unavailable',
      circuits: { anthropic: breakers.anthropic.state, ollama: breakers.ollama.state },
    });
    return true;
  }
  if (url === '/metrics') {
    if (!metrics) { send(res, 503, { error: 'prom-client not installed' }); return true; }
    metrics.register.metrics().then(data => {
      res.writeHead(200, { 'Content-Type': metrics.register.contentType });
      res.end(data);
    });
    return true;
  }
  if (url === '/cost') {
    const total = Object.values(costState.byModel).reduce((a, b) => a + b, 0);
    send(res, 200, { date: costState.date, total_usd: round2(total), by_model: costState.byModel, daily_limit_usd: CFG.COST_DAILY_LIMIT_USD });
    return true;
  }
  return false;
}

function send(res, code, body) {
  if (res.headersSent) return;
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}
function round2(n) { return Math.round(n * 100) / 100; }

// ── Read request body with size limit ────────────────────────────────────
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > CFG.MAX_REQUEST_BYTES) {
        req.destroy();
        return reject(Object.assign(new Error('request_too_large'), { statusCode: 413 }));
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

// ── Upstream forward with retry ──────────────────────────────────────────
function forwardOnce(targetOpts, body) {
  return new Promise((resolve, reject) => {
    const lib = targetOpts.protocol === 'https:' ? https : http;
    const pReq = lib.request(targetOpts, (pRes) => resolve(pRes));
    pReq.on('error', reject);
    pReq.setTimeout(300000, () => { pReq.destroy(new Error('upstream_timeout')); });
    pReq.write(body);
    pReq.end();
  });
}

async function forwardWithRetry(targetOpts, body, breaker, reqLogger) {
  let lastErr;
  for (let attempt = 0; attempt <= CFG.RETRY_MAX; attempt++) {
    if (!breaker.canAttempt()) {
      throw Object.assign(new Error('circuit_open'), { statusCode: 503 });
    }
    try {
      const pRes = await forwardOnce(targetOpts, body);
      if (pRes.statusCode >= 500) {
        pRes.resume();
        breaker.recordFailure();
        lastErr = Object.assign(new Error(`upstream_${pRes.statusCode}`), { statusCode: pRes.statusCode });
        if (attempt < CFG.RETRY_MAX) {
          if (metrics) metrics.retriesTotal.inc({ provider: breaker.name });
          reqLogger.warn({ event: 'retry', attempt: attempt + 1, status: pRes.statusCode });
          await sleep(CFG.RETRY_BASE_MS * Math.pow(2, attempt) + Math.random() * 100);
          continue;
        }
        throw lastErr;
      }
      breaker.recordSuccess();
      return pRes;
    } catch (err) {
      if (err.statusCode === 503 && err.message === 'circuit_open') throw err;
      breaker.recordFailure();
      lastErr = err;
      if (attempt < CFG.RETRY_MAX) {
        if (metrics) metrics.retriesTotal.inc({ provider: breaker.name });
        reqLogger.warn({ event: 'retry', attempt: attempt + 1, err: err.message });
        await sleep(CFG.RETRY_BASE_MS * Math.pow(2, attempt) + Math.random() * 100);
        continue;
      }
      throw err;
    }
  }
  throw lastErr;
}
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// ── Main request handler ─────────────────────────────────────────────────
let shuttingDown = false;
let inflight = 0;
async function handle(req, res) {
  if (shuttingDown) { send(res, 503, { error: 'shutting_down' }); return; }
  const requestId = crypto.randomBytes(8).toString('hex');
  const start = Date.now();
  const reqLogger = logger.child ? logger.child({ request_id: requestId }) : logger;
  res.setHeader('X-Request-Id', requestId);

  if (handleInternalEndpoint(req, res)) return;
  if (!checkAuth(req)) { send(res, 401, { error: 'unauthorized' }); return; }

  let body;
  try { body = await readBody(req); }
  catch (err) { send(res, err.statusCode || 400, { error: err.message }); return; }

  let parsed = {};
  try { parsed = body.length ? JSON.parse(body.toString('utf8')) : {}; } catch {}

  const rawModel = parsed.model || '';
  const { provider, model } = classifyModel(rawModel);
  const breaker = breakers[provider];
  const limiter = limiters[provider];

  if (!limiter.tryConsume()) {
    if (metrics) metrics.rateLimitRejected.inc({ provider });
    reqLogger.warn({ event: 'rate_limited', provider });
    send(res, 429, { error: 'rate_limit_exceeded', retry_after_sec: 60 });
    return;
  }

  if (provider === 'ollama') parsed = applyGlmRigor(parsed);
  else if (provider === 'anthropic') parsed = injectPromptCaching(parsed);
  parsed.model = model;

  const outBody = Buffer.from(JSON.stringify(parsed));
  const fwdHeaders = { ...req.headers };
  delete fwdHeaders.host;
  delete fwdHeaders['content-length'];
  fwdHeaders['content-length'] = String(outBody.length);

  let targetOpts;
  if (provider === 'anthropic') {
    targetOpts = {
      protocol: 'https:', hostname: CFG.ANTHROPIC_HOST, port: 443,
      path: req.url, method: req.method,
      headers: { ...fwdHeaders, host: CFG.ANTHROPIC_HOST },
    };
  } else {
    targetOpts = {
      protocol: 'http:', hostname: CFG.OLLAMA_HOST, port: CFG.OLLAMA_PORT,
      path: '/v1/messages', method: 'POST',
      headers: {
        ...fwdHeaders, host: `${CFG.OLLAMA_HOST}:${CFG.OLLAMA_PORT}`,
        authorization: 'Bearer ollama', 'x-api-key': 'ollama',
      },
    };
  }

  reqLogger.info({
    event: 'request_start', provider, model, path: req.url,
    user_agent: req.headers['user-agent'] || '',
  });
  auditLog({ event: 'request', request_id: requestId, provider, model, path: req.url });

  inflight++;
  if (metrics) metrics.inflight.inc();

  let pRes;
  try {
    pRes = await forwardWithRetry(targetOpts, outBody, breaker, reqLogger);
  } catch (err) {
    const statusCode = err.statusCode || 502;
    reqLogger.error({ event: 'request_failed', provider, model, err: err.message, statusCode });
    auditLog({ event: 'request_failed', request_id: requestId, provider, model, err: err.message });
    if (metrics) {
      metrics.requestsTotal.inc({ provider, model, status_class: `${Math.floor(statusCode / 100)}xx` });
      metrics.requestDuration.observe({ provider, model }, (Date.now() - start) / 1000);
      metrics.inflight.dec();
    }
    inflight--;
    send(res, statusCode, { error: { type: 'proxy_error', message: err.message, request_id: requestId } });
    return;
  }

  res.writeHead(pRes.statusCode, pRes.headers);
  let captured = Buffer.alloc(0);
  const contentType = pRes.headers['content-type'] || '';
  const isJson = contentType.includes('application/json');
  const isSSE = contentType.includes('text/event-stream');
  let sseRemainder = '';
  const sseTok = { input: 0, output: 0, cacheCreate: 0, cacheRead: 0 };
  pRes.on('data', (chunk) => {
    res.write(chunk);
    if (isSSE) {
      sseRemainder += chunk.toString('utf8');
      const lines = sseRemainder.split('\n');
      sseRemainder = lines.pop();
      for (const line of lines) {
        if (!line.startsWith('data: ')) continue;
        try {
          const evt = JSON.parse(line.slice(6));
          if (evt.type === 'message_start' && evt.message?.usage) {
            const u = evt.message.usage;
            sseTok.input = u.input_tokens || 0;
            sseTok.cacheCreate = u.cache_creation_input_tokens || 0;
            sseTok.cacheRead = u.cache_read_input_tokens || 0;
          } else if (evt.type === 'message_delta' && evt.usage) {
            sseTok.output = evt.usage.output_tokens || 0;
          }
        } catch {}
      }
    } else if (isJson && captured.length < 1024 * 1024) {
      captured = Buffer.concat([captured, chunk]);
    }
  });
  pRes.on('end', () => {
    res.end();
    const durSec = (Date.now() - start) / 1000;
    const statusClass = `${Math.floor(pRes.statusCode / 100)}xx`;
    if (metrics) {
      metrics.requestsTotal.inc({ provider, model, status_class: statusClass });
      metrics.requestDuration.observe({ provider, model }, durSec);
      metrics.inflight.dec();
    }
    inflight--;
    if (isSSE && (sseTok.input || sseTok.output)) {
      trackCost(model, sseTok.input, sseTok.output);
      reqLogger.info({
        event: 'request_end', provider, model, status: pRes.statusCode,
        duration_sec: durSec, input_tokens: sseTok.input, output_tokens: sseTok.output,
        cache_creation_tokens: sseTok.cacheCreate, cache_read_tokens: sseTok.cacheRead,
      });
      auditLog({
        event: 'request_end', request_id: requestId, provider, model,
        status: pRes.statusCode, duration_sec: durSec,
        input_tokens: sseTok.input, output_tokens: sseTok.output,
        cache_creation_tokens: sseTok.cacheCreate, cache_read_tokens: sseTok.cacheRead,
      });
    } else if (isJson && captured.length) {
      try {
        const parsedRes = JSON.parse(captured.toString('utf8'));
        const u = parsedRes.usage || {};
        const inputTok = u.input_tokens || 0;
        const outputTok = u.output_tokens || 0;
        if (inputTok || outputTok) trackCost(model, inputTok, outputTok);
        reqLogger.info({
          event: 'request_end', provider, model, status: pRes.statusCode,
          duration_sec: durSec, input_tokens: inputTok, output_tokens: outputTok,
        });
        auditLog({
          event: 'request_end', request_id: requestId, provider, model,
          status: pRes.statusCode, duration_sec: durSec,
          input_tokens: inputTok, output_tokens: outputTok,
        });
      } catch {
        reqLogger.info({ event: 'request_end', provider, model, status: pRes.statusCode, duration_sec: durSec });
      }
    } else {
      reqLogger.info({ event: 'request_end', provider, model, status: pRes.statusCode, duration_sec: durSec });
      auditLog({ event: 'request_end', request_id: requestId, provider, model, status: pRes.statusCode, duration_sec: durSec });
    }
  });
  pRes.on('error', (err) => {
    reqLogger.error({ event: 'response_stream_error', err: err.message });
    if (!res.writableEnded) res.end();
  });
}

// ── Server + graceful shutdown ───────────────────────────────────────────
const server = http.createServer((req, res) => {
  Promise.resolve(handle(req, res)).catch((err) => {
    logger.error({ event: 'handler_crashed', err: err.message, stack: err.stack });
    try { send(res, 500, { error: 'internal_error' }); } catch {}
  });
});

function gracefulShutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.info({ event: 'shutdown_start', signal, inflight });
  server.close(() => {
    logger.info({ event: 'shutdown_complete' });
    if (auditStream) auditStream.end();
    process.exit(0);
  });
  setTimeout(() => {
    logger.warn({ event: 'shutdown_force' });
    process.exit(1);
  }, 30000).unref();
}
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));
process.on('uncaughtException', (err) => {
  logger.error({ event: 'uncaught_exception', err: err.message, stack: err.stack });
});
process.on('unhandledRejection', (err) => {
  logger.error({ event: 'unhandled_rejection', err: err && err.message, stack: err && err.stack });
});

// ── Boot (skip when required as a module) ────────────────────────────────
if (require.main === module) {
  initAudit();
  server.listen(CFG.LISTEN_PORT, CFG.LISTEN_HOST, () => {
    logger.info({
      event: 'listening',
      host: CFG.LISTEN_HOST, port: CFG.LISTEN_PORT,
      anthropic: `https://${CFG.ANTHROPIC_HOST}`,
      ollama: `http://${CFG.OLLAMA_HOST}:${CFG.OLLAMA_PORT}`,
      glm_thinking: CFG.GLM_THINKING_BUDGET,
      glm_temp: CFG.GLM_TEMPERATURE,
      rate_limit_rpm: CFG.RATE_LIMIT_RPM,
      circuit_threshold: CFG.CIRCUIT_THRESHOLD,
      auth_required: !!CFG.PROXY_AUTH_TOKEN,
      metrics: !!metrics,
      audit_file: CFG.AUDIT_FILE,
    });
  });
}

// ── Exports for testing ──────────────────────────────────────────────────
module.exports = {
  CFG, classifyModel, applyGlmRigor, injectPromptCaching, TokenBucket, CircuitBreaker,
  trackCost, costState, PRICING,
  _auth: (req, token) => { const prev = CFG.PROXY_AUTH_TOKEN; CFG.PROXY_AUTH_TOKEN = token; const r = checkAuth(req); CFG.PROXY_AUTH_TOKEN = prev; return r; },
  _breakers: breakers, _limiters: limiters,
};
