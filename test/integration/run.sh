#!/usr/bin/env bash
# Runs the real-SDK integration suites against a freshly started Arc.
#
#   test/integration/run.sh
#
# Starts Arc on ARC_PORT (default 4010) with the dev database, creates an app with
# client events, encryption and a webhook endpoint, runs the JavaScript client SDK
# and Python server SDK suites, then stops Arc.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT=$(pwd)
export ARC_HOST=${ARC_HOST:-localhost}
export ARC_PORT=${ARC_PORT:-4010}
export ARC_WEBHOOK_PORT=${ARC_WEBHOOK_PORT:-4099}

(cd test/integration/js && npm install --silent)
if [ ! -x test/integration/python/.venv/bin/python ]; then
  python3 -m venv test/integration/python/.venv
  test/integration/python/.venv/bin/pip install -q -r test/integration/python/requirements.txt
fi

mix ecto.create --quiet && mix ecto.migrate --quiet

CREDS=$(mix arc.apps.create --name "integration-$(date +%s)" --client-events --encryption \
  --webhook-url "http://127.0.0.1:${ARC_WEBHOOK_PORT}/hook" \
  --webhook-events channel_occupied,channel_vacated,member_added,member_removed | tail -n 1)

export ARC_APP_ID=$(echo "$CREDS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
export ARC_APP_KEY=$(echo "$CREDS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')
export ARC_APP_SECRET=$(echo "$CREDS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["secret"])')
export ARC_MASTER_KEY=$(echo "$CREDS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["encryption_master_key"])')

PORT=$ARC_PORT mix phx.server > "$ROOT/_build/integration-server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  if curl -fs "http://${ARC_HOST}:${ARC_PORT}/health/ready" > /dev/null; then break; fi
  sleep 1
done

cd test/integration/js
node --test --test-concurrency=1 --test-timeout=120000 ${ARC_TEST_ARGS:-} sdk.test.js server_sdk.test.js
