// An audience event: N clients subscribe to one channel and a backend publishes
// notifications to it. The shape of a live show, an auction, or a status page.
//
// Every knob is an environment variable so the same script serves a 300-client
// rehearsal against staging and a 50k run against a benchmark box:
//
//   CONNECTIONS      concurrent subscribers                    (default 300)
//   RATE             publishes per second from the backend     (default 2)
//   RAMP_SECONDS     time to reach CONNECTIONS                  (default 60)
//   DURATION_SECONDS how long to publish once everyone is on   (default 300)
//   CHANNEL          channel name                              (default event-notifications)
//   PRIVATE          1 = use a private channel with signed auth (default 0)
//   PAYLOAD_BYTES    size of each notification's padding       (default 512)
//   P99_MS           receive-latency bar                       (default 1000)
//
// Credentials and endpoints come from the shared lib: ARC_WS_URL, ARC_API_URL,
// ARC_APP_ID, ARC_APP_KEY, ARC_APP_SECRET. See loadtest/README.md, "Against a
// deployed Arc", for a copy-paste run.
import exec from 'k6/execution';
import {
  connect,
  subscribe,
  keepalive,
  holdFor,
  publish,
  channelAuth,
  requireCredentials,
  summary,
} from './lib.js';

const CONNECTIONS = Number(__ENV.CONNECTIONS || 300);
const RATE = Number(__ENV.RATE || 2);
const RAMP = Number(__ENV.RAMP_SECONDS || 60);
const DURATION = Number(__ENV.DURATION_SECONDS || 300);
const CHANNEL = __ENV.CHANNEL || 'event-notifications';
const PRIVATE = __ENV.PRIVATE === '1';
const PAYLOAD_BYTES = Number(__ENV.PAYLOAD_BYTES || 512);
const P99_MS = Number(__ENV.P99_MS || 1000);

const channelName = PRIVATE && !CHANNEL.startsWith('private-') ? `private-${CHANNEL}` : CHANNEL;
const padding = 'x'.repeat(PAYLOAD_BYTES);

export const options = {
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    audience: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: `${RAMP}s`, target: CONNECTIONS },
        { duration: `${DURATION + 30}s`, target: CONNECTIONS },
      ],
      gracefulStop: '30s',
      exec: 'audience',
    },
    backend: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: `${DURATION}s`,
      // Start once the audience is in place, so every publish has every subscriber.
      startTime: `${RAMP + 10}s`,
      preAllocatedVUs: 5,
      maxVUs: 50,
      exec: 'backend',
    },
  },
  thresholds: {
    // Declared so the handshake-vs-session split survives into the summary. The reason
    // for each is printed once on the console the first time it is seen.
    'arc_ws_closed{during:handshake}': ['count>=0'],
    'arc_connect_errors{during:handshake}': ['count>=0'],
    // End to end: backend POST to client receive, measured by the client's clock
    // against sent_at in the payload. Run k6 on a machine with NTP.
    arc_receive_latency_ms: [`p(99)<${P99_MS}`],
    // Every client must get on, and every publish must be accepted.
    arc_connect_failed: ['rate<0.01'],
    'http_req_failed{name:publish}': ['rate<0.001'],
    // Nothing the protocol rejects: a non-zero count here is a bug or a bad channel name.
    arc_protocol_errors: ['count==0'],
  },
};

export function setup() {
  requireCredentials();
  return { channel: channelName };
}

export function audience() {
  connect({
    onReady(ws, socketId) {
      subscribe(ws, channelName, PRIVATE ? { auth: channelAuth(socketId, channelName) } : {});
      keepalive(ws);
      // Every client closes at the same moment, just after the last publish and before
      // the scenario ends, so k6 never has to interrupt an iteration.
      const closeAt = exec.scenario.startTime + (RAMP + DURATION + 25) * 1000;
      holdFor(ws, Math.max(1000, closeAt - Date.now()));
    },
  });
}

export function backend() {
  publish(channelName, 'notification', { padding });
}

export function handleSummary(data) {
  const subs = data.metrics.arc_events_received ? data.metrics.arc_events_received.values.count : 0;
  const pubs = data.metrics.arc_events_published ? data.metrics.arc_events_published.values.count : 0;
  // Per-tag breakdowns of why connections ended, for the summary and the console.
  const breakdown = (prefix) =>
    Object.keys(data.metrics)
      .filter((k) => k.startsWith(prefix + '{'))
      .reduce((acc, k) => Object.assign(acc, { [k.slice(prefix.length)]: data.metrics[k].values.count }), {});
  const closes = breakdown('arc_ws_closed');
  const errors = breakdown('arc_connect_errors');
  const lines = [];
  if (Object.keys(closes).length) lines.push('connections closed: ' + JSON.stringify(closes));
  if (Object.keys(errors).length) lines.push('connect errors: ' + JSON.stringify(errors));
  const out = summary('event', data, {
    connections: CONNECTIONS,
    rate: RATE,
    channel: channelName,
    payload_bytes: PAYLOAD_BYTES,
    published: pubs,
    received: subs,
    // Every publish should reach every subscriber that was connected at the time.
    expected_receives_at_full_audience: pubs * CONNECTIONS,
    closes,
    connect_errors: errors,
  });
  if (lines.length) out.stdout += lines.join('\n') + '\n';
  return out;
}
