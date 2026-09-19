#!/usr/bin/env bash
# Runs every scenario at a small scale to check the scripts and the server end to end.
# This is not the performance bar; see README.md for full-scale runs.
#
#   ARC_APP_ID=.. ARC_APP_KEY=.. ARC_APP_SECRET=.. loadtest/smoke.sh
#
# The app needs client events on and presence limits off.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
run() {
  local name=$1; shift
  if env "$@" k6 run -q "loadtest/$name.js"; then
    echo "ok   $name"
  else
    echo "FAIL $name"; status=1
  fi
}

run api_throughput  RATE=200 DURATION=10s
run fanout_wide     CONNECTIONS=200 RATE=10 RAMP_SECONDS=5 DURATION_SECONDS=10
run fanout_many     CONNECTIONS=300 CHANNELS=50 RATE=50 RAMP_SECONDS=5 DURATION_SECONDS=10
run presence_churn  MEMBERS=200 CHANNELS=10 CHURN_RATE=20 RAMP_SECONDS=5 DURATION_SECONDS=10 SETTLE_SECONDS=5
run client_events   CLIENTS=100 RAMP_SECONDS=5 DURATION_SECONDS=10 ABUSERS=2
run reconnect_storm CONNECTIONS=300 RAMP_SECONDS=5 HOLD_AFTER_SECONDS=5
run connect_ramp    TARGET=300 RAMP=10s HOLD=10s
run soak            CONNECTIONS=100 HOURS=0.005 RATE=5 RECYCLE_MINUTES=0.1
exit $status
