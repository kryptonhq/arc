# Load tests

k6 scripts that drive Arc over its public interfaces only, so the generator's own
performance is independent of the server being measured. Each run writes a JSON
summary to `loadtest/results/<scenario>.json`.

## Running

Create an app with client events on and presence limits off, against the node you
will test:

```bash
bin/arc rpc 'IO.puts(Jason.encode!(Arc.Release.create_app(%{"name" => "load", "client_events_enabled" => true, "enable_presence_limits" => false})))'
# or, from a checkout pointed at the same database, before the node starts:
mix arc.apps.create --name load --client-events --unlimited-presence
```

Then:

```bash
export ARC_WS_URL=ws://arc.example.com:4000 ARC_API_URL=http://arc.example.com:4000
export ARC_APP_ID=... ARC_APP_KEY=... ARC_APP_SECRET=...
k6 run loadtest/fanout_wide.js
```

`loadtest/smoke.sh` runs every scenario at a small scale; CI runs it against the
compose stack. It checks the scripts and the server end to end, not the performance
bars.

## Against a deployed Arc

`event.js` is the scenario to rehearse a real audience: N clients on one channel, a
backend publishing notifications, end-to-end latency measured at the client. It runs
unchanged against staging or production through TLS and a tunnel or balancer.

1. In the dashboard, create an app for load testing and copy its id, key and secret.
   Do not use the app real clients connect with: the test's connections and publishes
   count against that app's limits.
2. Put the endpoints and credentials in an env file:

   ```bash
   cp loadtest/.env.example loadtest/.env   # edit it, then:
   set -a; source loadtest/.env; set +a
   ```

3. Run the rehearsal. 300 clients, two notifications a second for five minutes:

   ```bash
   k6 run loadtest/event.js
   ```

   Knobs, all optional:

   ```bash
   CONNECTIONS=300 RATE=2 RAMP_SECONDS=60 DURATION_SECONDS=300 \
   CHANNEL=event-notifications PRIVATE=0 PAYLOAD_BYTES=512 P99_MS=1000 \
   k6 run loadtest/event.js
   ```

   `PRIVATE=1` subscribes to `private-<CHANNEL>` with a signed auth token, the way
   an app with authenticated channels would. `P99_MS` is the latency bar; 1000 ms is
   generous for a run over the public internet, 200 ms is the in-datacentre bar.

4. Read the result. The summary prints PASS or FAIL per threshold and writes
   `loadtest/results/event.json` with the numbers. The ones that matter:

   | Metric | Means |
   | --- | --- |
   | `arc_receive_latency_ms` p99 | Backend POST to client receive, end to end |
   | `arc_connect_failed` | Clients that never completed the handshake |
   | `http_req_failed{name:publish}` | Publishes the API refused |
   | `arc_protocol_errors` | Frames the server rejected; must be zero |
   | `received` vs `expected_receives_at_full_audience` | Fan-out completeness. Lower during the ramp is expected; lower at steady state is a dropped connection |

If clients fail to connect, the console prints the first close code and error reason
seen, and the summary splits closes and errors into handshake versus session. The common
one behind a proxy or tunnel: many `close during handshake` and thousands of iterations
instead of one per client. That is the per-address connection limit treating every
client as one address. Confirm with `arc_rate_limit_hits_total{kind="connect"}` on the
server's `/metrics`, and fix it by setting `ARC_TRUSTED_PROXIES` on the server to the
proxy's network. On the server, also watch `arc_connections_active` climb to
`CONNECTIONS` and stay there. Clocks matter: latency compares the client's clock with `sent_at` from the
publisher, and both run in this one k6 process, so it is exact.

One machine opens up to ~28k connections to one address; 300 is nowhere near that.
For thousands, see "Generating 100k connections" below.

## Scenarios

| Script | Shape | Passing bar on 4 vCPU / 8 GB | Scale knobs |
| --- | --- | --- | --- |
| `connect_ramp.js` | Ramp to 100k idle connections, hold 10 min | Sustained, memory stable, p99 handshake < 500 ms | `TARGET`, `RAMP`, `HOLD` |
| `fanout_wide.js` | 50k connections on one channel, 10 events/s | p99 receive latency < 200 ms | `CONNECTIONS`, `RATE`, `RAMP_SECONDS`, `DURATION_SECONDS` |
| `fanout_many.js` | 50k connections across 10k channels, 100 events/s | p99 < 200 ms | `CONNECTIONS`, `CHANNELS`, `RATE` |
| `presence_churn.js` | 10k presence members, 500 joins and leaves/s | Member lists exact at the end (`arc_presence_drift == 0`) | `MEMBERS`, `CHANNELS`, `CHURN_RATE` |
| `client_events.js` | 10k private-channel clients, 1 client event/s each | No well-behaved client limited; abusers limited | `CLIENTS`, `GROUP`, `ABUSERS` |
| `api_throughput.js` | 5k publishes/s | p99 < 50 ms, zero 5xx | `RATE`, `DURATION`, `CHANNELS` |
| `reconnect_storm.js` | 50k connections drop at once and reconnect | Every client back within 60 s | `CONNECTIONS`, `RAMP_SECONDS` |
| `soak.js` | 20k connections, moderate traffic, 12 hours | Flat server memory | `CONNECTIONS`, `HOURS`, `RATE`, `RECYCLE_MINUTES` |
| `event.js` | An audience: N clients on one channel, a backend publishing | p99 receive < `P99_MS` (1000 default), zero connect failures, zero protocol errors | `CONNECTIONS`, `RATE`, `RAMP_SECONDS`, `DURATION_SECONDS`, `CHANNEL`, `PRIVATE`, `PAYLOAD_BYTES`, `P99_MS` |

Receive latency is measured end to end: publishers embed `sent_at` in the event and
subscribers compare it with their own clock, so run publishers and subscribers from
the same k6 process (as the scripts do) or from machines with synchronised clocks.

The soak recycles connections every ~30 minutes and samples `/metrics` once a minute
(`arc_server_memory_bytes`, `arc_server_binary_bytes`, `arc_server_ets_bytes`). Run it
with `--out json=soak.json` and compare the first and last hours; a leak shows up as
steady growth in binary or ETS memory, usually hours in.

## Generating 100k connections

One client IP can open roughly 28k–64k connections to one server address and port
(the ephemeral port range). For the 50k and 100k scenarios, either:

- run k6 from several machines (`k6 run --execution-segment ...`), or
- give the generator several source addresses: `k6 run --local-ips=10.0.0.10-10.0.0.13 ...`

Raise file descriptor limits on the generator too (`ulimit -n 1048576`).

## What to watch on the server

`arc_connections_active`, `vm_total_run_queue_lengths_total`, memory by type
(`vm_memory_binary` is where leaks show), and scheduler utilisation. A run that meets
its latency bar while the run queue climbs would have failed with a longer duration.

## Last recorded runs

Full-scale runs on the reference 4 vCPU / 8 GB hardware have not been recorded yet.
Record each one here (hardware, Arc version, scenario, headline numbers, pass/fail)
so a regression is visible rather than a matter of opinion.

| Date | Hardware | Scenario | Scale | Result |
| --- | --- | --- | --- | --- |
| 2026-09-19 | Apple M4 Pro (12 cores, 24 GB), Arc in Docker, k6 on the same machine | `smoke.sh` (all eight) | 100–300 connections each | All thresholds passed: API publish p99 2.6 ms; fan-out receive p99 4–17 ms; handshake p99 ≤ 30 ms; presence drift 0; 300/300 reconnected within 32 ms. Smoke scale only; not evidence for the bars above. |
