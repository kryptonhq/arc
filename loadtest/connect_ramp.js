// Ramp to 100k idle connections and hold for 10 minutes.
// Bar (4 vCPU / 8 GB): sustained, memory stable, p99 handshake under 500 ms.
import { cfg, connect, keepalive, holdFor, requireCredentials, summary, scrape } from './lib.js';
import { Trend } from 'k6/metrics';

const TARGET = Number(__ENV.TARGET || 100000);
const RAMP = __ENV.RAMP || '10m';
const HOLD = __ENV.HOLD || '10m';
const serverMemory = new Trend('arc_server_memory_bytes');

export const options = {
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    idle: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: RAMP, target: TARGET },
        { duration: HOLD, target: TARGET },
      ],
      gracefulRampDown: '30s',
      gracefulStop: '30s',
    },
    sampler: { executor: 'constant-arrival-rate', rate: 1, timeUnit: '30s', duration: `${parseDuration(RAMP) + parseDuration(HOLD)}s`, preAllocatedVUs: 1, exec: 'sample' },
  },
  thresholds: {
    arc_handshake_ms: ['p(99)<500'],
    arc_connect_failed: ['rate<0.01'],
  },
};

function parseDuration(d) {
  const m = String(d).match(/^(\d+)(s|m|h)$/);
  return m ? Number(m[1]) * { s: 1, m: 60, h: 3600 }[m[2]] : 600;
}

export function setup() {
  requireCredentials();
}

export default function () {
  connect({
    onReady(ws) {
      keepalive(ws, 60000);
      // Hold longer than the whole test; the executor stops the VU at the end.
      holdFor(ws, (parseDuration(RAMP) + parseDuration(HOLD) + 60) * 1000);
    },
  });
}

export function sample() {
  const m = scrape();
  if (m.memory) serverMemory.add(m.memory);
}

export function handleSummary(data) {
  return summary('connect_ramp', data, { target: TARGET, ws: cfg.ws });
}
