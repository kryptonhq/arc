// 10k presence members, 500 joins and leaves per second.
// Bar: member lists correct at the end, no drift.
//
// The app must have presence limits disabled (or a ceiling above MEMBERS_PER_CHANNEL
// plus churn): mix arc.apps.create --name load --unlimited-presence
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { cfg, api, connect, subscribe, channelAuth, keepalive, holdFor, requireCredentials, summary } from './lib.js';

const MEMBERS = Number(__ENV.MEMBERS || 10000);
const CHANNELS = Number(__ENV.CHANNELS || 100);
const CHURN_RATE = Number(__ENV.CHURN_RATE || 500);
const RAMP = Number(__ENV.RAMP_SECONDS || 120);
const DURATION = Number(__ENV.DURATION_SECONDS || 300);
const SETTLE = Number(__ENV.SETTLE_SECONDS || 20);
const drift = new Counter('arc_presence_drift');
// Churn ends at CHURN_END; the check runs SETTLE seconds later, while every stable
// member is still connected; members leave after the check.
const CHURN_END = RAMP + 10 + DURATION;
const VERIFY_AT = CHURN_END + SETTLE;
const MEMBERS_LEAVE = VERIFY_AT + 60;

export const options = {
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
  setupTimeout: '60s',
  scenarios: {
    members: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: `${RAMP}s`, target: MEMBERS },
        { duration: `${MEMBERS_LEAVE - RAMP + 30}s`, target: MEMBERS },
      ],
      exec: 'member',
    },
    verify: {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 1,
      startTime: `${VERIFY_AT}s`,
      maxDuration: '120s',
      exec: 'verify',
    },
    churn: {
      executor: 'constant-arrival-rate',
      rate: CHURN_RATE,
      timeUnit: '1s',
      duration: `${DURATION}s`,
      startTime: `${RAMP + 10}s`,
      preAllocatedVUs: CHURN_RATE * 3,
      maxVUs: CHURN_RATE * 6,
      exec: 'churner',
    },
  },
  thresholds: {
    arc_presence_drift: ['count==0'],
    arc_connect_failed: ['rate<0.01'],
  },
};

function join(channel, userId, holdMs) {
  connect({
    onReady(ws, socketId) {
      const channelData = JSON.stringify({ user_id: userId });
      subscribe(ws, channel, { auth: channelAuth(socketId, channel, channelData), channel_data: channelData });
      keepalive(ws);
      holdFor(ws, holdMs);
    },
  });
}

export function setup() {
  requireCredentials();
}

// Stable members stay for the whole run.
export function member() {
  join(`presence-churn-${__VU % CHANNELS}`, `stable-${__VU}`, MEMBERS_LEAVE * 1000);
}

// Churners join a random channel and leave 1–2 seconds later.
export function churner() {
  const id = `churn-${__VU}-${__ITER}`;
  join(`presence-churn-${Math.floor(Math.random() * CHANNELS)}`, id, 1000 + Math.random() * 1000);
}

// After churn stops, each channel must list exactly its stable members: no churner
// left behind, no stable member lost.
export function verify() {
  let total = 0;
  for (let c = 0; c < CHANNELS; c++) {
    const res = api('GET', `/apps/${cfg.appId}/channels/presence-churn-${c}/users`);
    if (res.status !== 200) continue;
    const users = JSON.parse(res.body).users.map((u) => u.id);
    const leftovers = users.filter((id) => id.startsWith('churn-'));
    total += users.filter((id) => id.startsWith('stable-')).length;
    if (leftovers.length > 0) drift.add(leftovers.length);
  }
  const ok = check(total, { 'every stable member present': (t) => t === MEMBERS });
  if (!ok) drift.add(Math.abs(MEMBERS - total));
}

export function handleSummary(data) {
  return summary('presence_churn', data, { members: MEMBERS, channels: CHANNELS, churn_rate: CHURN_RATE });
}
