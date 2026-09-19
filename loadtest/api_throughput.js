// 5k publishes per second against the HTTP API.
// Bar: p99 under 50 ms, zero 5xx.
import { Counter } from 'k6/metrics';
import { publish, requireCredentials, summary } from './lib.js';

const RATE = Number(__ENV.RATE || 5000);
const DURATION = __ENV.DURATION || '5m';
const CHANNELS = Number(__ENV.CHANNELS || 1000);
const serverErrors = new Counter('arc_api_5xx');

export const options = {
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    api: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.ceil(RATE / 10),
      maxVUs: RATE,
    },
  },
  thresholds: {
    'http_req_duration{name:publish}': ['p(99)<50'],
    arc_api_5xx: ['count==0'],
  },
};

export function setup() {
  requireCredentials();
}

export default function () {
  const res = publish(`api-${Math.floor(Math.random() * CHANNELS)}`);
  if (res.status >= 500) serverErrors.add(1);
}

export function handleSummary(data) {
  return summary('api_throughput', data, { rate: RATE });
}
