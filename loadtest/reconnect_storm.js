// 50k connections drop at the same moment and all reconnect immediately.
// Bar: the node survives, and every client is back within 60 s.
import { Trend, Counter } from 'k6/metrics';
import { setTimeout } from 'k6/timers';
import { connect, subscribe, keepalive, holdFor, requireCredentials, summary } from './lib.js';

const CONNECTIONS = Number(__ENV.CONNECTIONS || 50000);
const RAMP = Number(__ENV.RAMP_SECONDS || 300);
const HOLD_AFTER = Number(__ENV.HOLD_AFTER_SECONDS || 90);

const recovery = new Trend('arc_reconnect_ms', true);
const recovered = new Counter('arc_reconnected');
const lost = new Counter('arc_not_reconnected');

export const options = {
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    storm: {
      executor: 'per-vu-iterations',
      vus: CONNECTIONS,
      iterations: 1,
      maxDuration: `${RAMP + 60 + HOLD_AFTER + 60}s`,
    },
  },
  thresholds: {
    arc_reconnect_ms: ['max<60000'],
    arc_not_reconnected: ['count==0'],
  },
};

export function setup() {
  requireCredentials();
  // Every VU drops its connection at this wall-clock instant.
  return { dropAt: Date.now() + (RAMP + 30) * 1000 };
}

export default function (data) {
  // Spread initial connects over the ramp.
  setTimeout(() => {
    connect({
      onReady(ws) {
        subscribe(ws, `storm-${__VU % 1000}`);
        keepalive(ws);
        setTimeout(() => ws.close(), Math.max(0, data.dropAt - Date.now()));
      },
      onClose() {
        const dropped = Date.now();
        let done = false;
        connect({
          onReady(ws) {
            done = true;
            recovery.add(Date.now() - dropped);
            recovered.add(1);
            subscribe(ws, `storm-${__VU % 1000}`);
            holdFor(ws, HOLD_AFTER * 1000);
          },
          onClose() {
            if (!done) lost.add(1);
          },
        });
      },
    });
  }, Math.random() * RAMP * 1000);
}

export function handleSummary(data) {
  return summary('reconnect_storm', data, { connections: CONNECTIONS });
}
