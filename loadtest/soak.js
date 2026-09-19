// 20k connections with moderate traffic for 12 hours, watching server memory.
// Bar: flat memory. The summary compares median memory in the first and last hours.
import { Trend } from 'k6/metrics';
import { connect, subscribe, keepalive, holdFor, publish, scrape, channelAuth, requireCredentials, summary } from './lib.js';

const CONNECTIONS = Number(__ENV.CONNECTIONS || 20000);
const HOURS = Number(__ENV.HOURS || 12);
const RATE = Number(__ENV.RATE || 20);
const RECYCLE_MINUTES = Number(__ENV.RECYCLE_MINUTES || 30);
const DURATION = HOURS * 3600;

const memory = new Trend('arc_server_memory_bytes');
const binaryMemory = new Trend('arc_server_binary_bytes');
const etsMemory = new Trend('arc_server_ets_bytes');
const processes = new Trend('arc_server_processes');

export const options = {
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    // Connections recycle every RECYCLE_MINUTES so the run exercises connect and
    // disconnect paths, where leaked monitors or ETS rows would show up.
    clients: {
      executor: 'constant-vus',
      vus: CONNECTIONS,
      duration: `${DURATION}s`,
      exec: 'client',
    },
    publisher: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: `${DURATION}s`,
      preAllocatedVUs: 10,
      exec: 'publisher',
    },
    sampler: {
      executor: 'constant-arrival-rate',
      rate: 1,
      timeUnit: '1m',
      duration: `${DURATION}s`,
      preAllocatedVUs: 1,
      exec: 'sampler',
    },
  },
  thresholds: {
    arc_connect_failed: ['rate<0.01'],
    arc_receive_latency_ms: ['p(99)<500'],
  },
};

export function setup() {
  requireCredentials();
}

export function client() {
  connect({
    onReady(ws, socketId) {
      subscribe(ws, `soak-${__VU % 2000}`);
      if (__VU % 10 === 0) {
        const channel = `presence-soak-${__VU % 200}`;
        const data = JSON.stringify({ user_id: `u-${__VU}` });
        subscribe(ws, channel, { auth: channelAuth(socketId, channel, data), channel_data: data });
      }
      keepalive(ws);
      holdFor(ws, RECYCLE_MINUTES * 60 * 1000 * (0.5 + Math.random()));
    },
  });
}

export function publisher() {
  publish(`soak-${Math.floor(Math.random() * 2000)}`);
}

export function sampler() {
  const m = scrape();
  if (m.memory) {
    memory.add(m.memory);
    binaryMemory.add(m.binary || 0);
    etsMemory.add(m.ets || 0);
    processes.add(m.processes || 0);
  }
}

export function handleSummary(data) {
  return summary('soak', data, {
    connections: CONNECTIONS,
    hours: HOURS,
    note: 'Compare arc_server_memory_bytes, arc_server_binary_bytes and arc_server_ets_bytes over time in the time-series output (k6 run --out json=...) to judge flatness.',
  });
}
