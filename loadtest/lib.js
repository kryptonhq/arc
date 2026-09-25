// Shared helpers for the Arc load tests.
//
// Configuration (environment variables):
//   ARC_WS_URL      ws://host:port        (default ws://localhost:4000)
//   ARC_API_URL     http://host:port      (default http://localhost:4000)
//   ARC_APP_ID, ARC_APP_KEY, ARC_APP_SECRET
//   ARC_METRICS_TOKEN                     (optional, for /metrics)
import { WebSocket } from 'k6/websockets';
import http from 'k6/http';
import crypto from 'k6/crypto';
import { Trend, Counter, Rate } from 'k6/metrics';
import { setInterval, clearInterval, setTimeout } from 'k6/timers';

export const cfg = {
  ws: __ENV.ARC_WS_URL || 'ws://localhost:4000',
  api: __ENV.ARC_API_URL || 'http://localhost:4000',
  appId: __ENV.ARC_APP_ID,
  key: __ENV.ARC_APP_KEY,
  secret: __ENV.ARC_APP_SECRET,
  metricsToken: __ENV.ARC_METRICS_TOKEN,
};

export const handshake = new Trend('arc_handshake_ms', true);
export const latency = new Trend('arc_receive_latency_ms', true);
export const received = new Counter('arc_events_received');
export const published = new Counter('arc_events_published');
export const connectFailed = new Rate('arc_connect_failed');
export const protocolErrors = new Counter('arc_protocol_errors');
// Why connections ended: close codes from the server (4100 over capacity, 4101 shutting
// down, 4102 slow consumer, 4201 pong timeout, 1006 abnormal) and connect errors by
// message. A failed handshake behind a proxy usually shows up here as 1006 plus an
// error mentioning the HTTP status; a 429 means the per-address limit is treating every
// client as one address (set ARC_TRUSTED_PROXIES on the server).
export const closed = new Counter('arc_ws_closed');
export const connectErrors = new Counter('arc_connect_errors');

// Each distinct reason is printed once by the first VU, so the console says why
// without every client repeating it (VUs do not share memory).
const seen = new Set();
function explain(kind, detail) {
  if (__VU !== 1) return;
  const key = `${kind}:${detail}`;
  if (seen.has(key)) return;
  seen.add(key);
  console.warn(`arc: first ${kind}: ${detail}`);
}

export function requireCredentials() {
  if (!cfg.appId || !cfg.key || !cfg.secret) {
    throw new Error('ARC_APP_ID, ARC_APP_KEY and ARC_APP_SECRET are required');
  }
}

const hmac = (data) => crypto.hmac('sha256', cfg.secret, data, 'hex');

// Signed HTTP API request, the same scheme the server SDKs use.
export function api(method, path, body, query = {}, params = {}) {
  const raw = body === undefined ? '' : JSON.stringify(body);
  const q = Object.assign(
    { auth_key: cfg.key, auth_timestamp: String(Math.floor(Date.now() / 1000)), auth_version: '1.0' },
    query,
  );
  if (raw) q.body_md5 = crypto.md5(raw, 'hex');
  const toSign = Object.keys(q).sort().map((k) => `${k}=${q[k]}`).join('&');
  q.auth_signature = hmac(`${method}\n${path}\n${toSign}`);
  const qs = Object.keys(q).map((k) => `${k}=${encodeURIComponent(q[k])}`).join('&');
  const url = `${cfg.api}${path}?${qs}`;
  const headers = { 'Content-Type': 'application/json' };
  return method === 'GET'
    ? http.get(url, Object.assign({ headers }, params))
    : http.request(method, url, raw, Object.assign({ headers }, params));
}

// Publishes with the send time embedded, so subscribers can measure receive latency.
export function publish(channel, name = 'load', extra = {}) {
  const data = JSON.stringify(Object.assign({ sent_at: Date.now() }, extra));
  const res = api('POST', `/apps/${cfg.appId}/events`, { name, channel, data }, {}, { tags: { name: 'publish' } });
  if (res.status === 200) published.add(1);
  return res;
}

export function channelAuth(socketId, channel, channelData) {
  const toSign = channelData ? `${socketId}:${channel}:${channelData}` : `${socketId}:${channel}`;
  return `${cfg.key}:${hmac(toSign)}`;
}

// Opens a client connection. `handlers.onReady(ws, socketId)` runs after the handshake;
// `handlers.onEvent(frame)` for every other frame. Latency is recorded for any event
// whose data carries `sent_at`.
export function connect(handlers = {}) {
  const started = Date.now();
  const ws = new WebSocket(`${cfg.ws}/app/${cfg.key}?protocol=7&client=k6&version=1.0&flash=false`);
  let ready = false;

  ws.onmessage = (msg) => {
    const frame = JSON.parse(msg.data);
    if (frame.event === 'pusher:connection_established') {
      ready = true;
      handshake.add(Date.now() - started);
      connectFailed.add(false);
      const socketId = JSON.parse(frame.data).socket_id;
      if (handlers.onReady) handlers.onReady(ws, socketId);
      return;
    }
    if (frame.event === 'pusher:error') protocolErrors.add(1, { code: String(frame.data && frame.data.code) });
    if (frame.event === 'pusher:ping') ws.send(JSON.stringify({ event: 'pusher:pong', data: {} }));
    if (typeof frame.data === 'string' && frame.data.indexOf('sent_at') !== -1) {
      try {
        const payload = JSON.parse(frame.data);
        if (payload.sent_at) {
          latency.add(Date.now() - payload.sent_at);
          received.add(1);
        }
      } catch (_) {}
    }
    if (handlers.onEvent) handlers.onEvent(frame, ws);
  };
  ws.onerror = (e) => {
    if (!ready) connectFailed.add(true);
    const reason = String((e && (e.error || e.message)) || 'unknown').slice(0, 120);
    connectErrors.add(1, { during: ready ? 'session' : 'handshake' });
    explain(ready ? 'error during session' : 'connect error', reason);
    if (handlers.onError) handlers.onError(e);
  };
  ws.onclose = (e) => {
    closed.add(1, { during: ready ? 'session' : 'handshake' });
    if (!ready || (e && e.code && e.code !== 1000 && e.code !== 1005)) {
      explain(ready ? 'close during session' : 'close during handshake', `code ${e && e.code}`);
    }
    if (handlers.onClose) handlers.onClose(e);
  };
  return ws;
}

export function subscribe(ws, channel, extra = {}) {
  ws.send(JSON.stringify({ event: 'pusher:subscribe', data: Object.assign({ channel }, extra) }));
}

// Keeps a connection alive with client pings, as SDKs do.
export function keepalive(ws, everyMs = 60000) {
  const timer = setInterval(() => {
    if (ws.readyState === 1) ws.send(JSON.stringify({ event: 'pusher:ping', data: {} }));
    else clearInterval(timer);
  }, everyMs);
  return timer;
}

// Holds a connection open for `ms`, then closes it; the VU iteration ends on close.
export function holdFor(ws, ms) {
  setTimeout(() => ws.close(), ms);
}

// Server-side numbers from /metrics, for the soak and for the summary files.
export function scrape() {
  const headers = cfg.metricsToken ? { Authorization: `Bearer ${cfg.metricsToken}` } : {};
  const res = http.get(`${cfg.api}/metrics`, { headers, tags: { name: 'metrics' } });
  const read = (name) => {
    const match = res.body && res.body.match(new RegExp(`^${name}(?:\\{[^}]*\\})? ([0-9.e+]+)$`, 'm'));
    return match ? Number(match[1]) : null;
  };
  return {
    memory: read('vm_memory_total'),
    binary: read('vm_memory_binary'),
    ets: read('vm_memory_ets'),
    runQueue: read('vm_total_run_queue_lengths_total'),
    processes: read('vm_system_counts_process_count'),
  };
}

export function summary(name, data, extra = {}) {
  const out = { scenario: name, finished_at: new Date().toISOString(), extra, metrics: {} };
  for (const key of Object.keys(data.metrics)) {
    const m = data.metrics[key];
    out.metrics[key] = { values: m.values, thresholds: m.thresholds || null };
  }
  const text = [`scenario ${name}`];
  for (const [k, m] of Object.entries(data.metrics)) {
    if (m.thresholds) {
      for (const [t, r] of Object.entries(m.thresholds)) text.push(`  ${r.ok ? 'PASS' : 'FAIL'} ${k} ${t}`);
    }
  }
  return {
    [`loadtest/results/${name}.json`]: JSON.stringify(out, null, 2),
    stdout: text.join('\n') + '\n',
  };
}

