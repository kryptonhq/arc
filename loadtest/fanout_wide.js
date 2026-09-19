// 50k connections on one channel, 10 events/s.
// Bar: p99 client receive latency under 200 ms.
import { connect, subscribe, keepalive, holdFor, publish, requireCredentials, summary } from './lib.js';

const CONNECTIONS = Number(__ENV.CONNECTIONS || 50000);
const RATE = Number(__ENV.RATE || 10);
const RAMP = Number(__ENV.RAMP_SECONDS || 300);
const DURATION = Number(__ENV.DURATION_SECONDS || 300);
const CHANNEL = __ENV.CHANNEL || 'fanout-wide';

export const options = {
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    subscribers: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: `${RAMP}s`, target: CONNECTIONS },
        { duration: `${DURATION + 30}s`, target: CONNECTIONS },
      ],
      exec: 'subscriber',
    },
    publisher: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: `${DURATION}s`,
      startTime: `${RAMP + 15}s`,
      preAllocatedVUs: 20,
      exec: 'publisher',
    },
  },
  thresholds: {
    arc_receive_latency_ms: ['p(99)<200'],
    arc_connect_failed: ['rate<0.01'],
    'http_req_failed{name:publish}': ['rate<0.001'],
  },
};

export function setup() {
  requireCredentials();
}

export function subscriber() {
  connect({
    onReady(ws) {
      subscribe(ws, CHANNEL);
      keepalive(ws);
      holdFor(ws, (RAMP + DURATION + 60) * 1000);
    },
  });
}

export function publisher() {
  publish(CHANNEL);
}

export function handleSummary(data) {
  return summary('fanout_wide', data, { connections: CONNECTIONS, rate: RATE });
}
