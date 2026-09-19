// 10k private-channel clients each sending 1 client event per second.
// Bar: rate limits enforced, no dropped frames under the limit.
//
// The app must allow client events: mix arc.apps.create --name load --client-events
import { Counter } from 'k6/metrics';
import { setInterval, clearInterval } from 'k6/timers';
import { connect, subscribe, channelAuth, holdFor, requireCredentials, summary } from './lib.js';

const CLIENTS = Number(__ENV.CLIENTS || 10000);
const GROUP = Number(__ENV.GROUP || 10); // clients per channel
const RAMP = Number(__ENV.RAMP_SECONDS || 120);
const DURATION = Number(__ENV.DURATION_SECONDS || 300);
const ABUSERS = Number(__ENV.ABUSERS || 10);

const sent = new Counter('arc_client_events_sent');
const got = new Counter('arc_client_events_received');
const limited = new Counter('arc_rate_limited');
const limitedUnderLimit = new Counter('arc_rate_limited_under_limit');

export const options = {
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    clients: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: `${RAMP}s`, target: CLIENTS },
        { duration: `${DURATION}s`, target: CLIENTS },
      ],
      exec: 'client',
    },
    abusers: {
      executor: 'per-vu-iterations',
      vus: ABUSERS,
      iterations: 1,
      startTime: `${RAMP}s`,
      exec: 'abuser',
    },
  },
  thresholds: {
    // Well-behaved clients are never limited, and the limit does bite abusers.
    arc_rate_limited_under_limit: ['count==0'],
    arc_rate_limited: ['count>0'],
    arc_connect_failed: ['rate<0.01'],
  },
};

export function setup() {
  requireCredentials();
}

function chat(channel, perSecond, onLimited, holdMs) {
  let timer = null;
  connect({
    onReady(ws, socketId) {
      subscribe(ws, channel, { auth: channelAuth(socketId, channel) });
      timer = setInterval(() => {
        for (let i = 0; i < perSecond; i++) {
          ws.send(JSON.stringify({ event: 'client-msg', channel, data: { sent_at: Date.now() } }));
          sent.add(1);
        }
      }, 1000);
      holdFor(ws, holdMs);
    },
    onClose() {
      if (timer) clearInterval(timer);
    },
    onEvent(frame) {
      if (frame.event === 'client-msg') got.add(1);
      if (frame.event === 'pusher:error' && frame.data && frame.data.code === 4301) onLimited();
    },
  });
}

export function client() {
  chat(`private-chat-${Math.floor(__VU / GROUP)}`, 1, () => limitedUnderLimit.add(1), (DURATION + RAMP) * 1000);
}

export function abuser() {
  chat(`private-abuse-${__VU}`, 25, () => limited.add(1), 20000);
}

export function handleSummary(data) {
  return summary('client_events', data, { clients: CLIENTS, group: GROUP });
}
