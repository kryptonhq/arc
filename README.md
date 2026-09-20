# Arc

Arc is a self-hosted realtime messaging server: persistent WebSocket connections,
channel-based pub/sub, presence, and a signed HTTP API that application backends call
to publish events.

Arc speaks the **Channels protocol, version 7**. Existing client SDKs for that
protocol (JavaScript, iOS, Android, Flutter) and the Python server SDK used from
Django work against Arc by changing the host and credentials only. Arc's own SDKs will
follow; until then, the existing ones are the supported clients.

> **Keep `ARC_ENCRYPTION_KEY` safe and backed up.** It encrypts every app secret,
> encryption master key, and webhook secret at rest. **If it is lost, those secrets
> cannot be recovered and every app must be issued new credentials.**

## Contents

- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Keycloak setup](#keycloak-setup)
- [Using Arc from a browser and from Django](#using-arc-from-a-browser-and-from-django)
- [Protocol reference](#protocol-reference)
- [HTTP API](#http-api)
- [Webhooks](#webhooks)
- [Operations](#operations)
- [Releases](#releases)
- [Development](#development)
- [License](#license)

## Quick start

```bash
docker compose up --build
```

This starts Arc on <http://localhost:4000>, Postgres, and a Keycloak realm that is
already configured. Open <http://localhost:4000>, sign in as **admin / admin**, and
create an app. The credentials page shows the app id, key, secret, host, and port,
with snippets for a browser client and a Django `settings.py`.

Keycloak is addressed as `http://keycloak.localhost:8180` by both your browser and the
Arc container, so the token issuer is the same on both sides. Most browsers resolve
`*.localhost` to `127.0.0.1`; if yours does not, add `127.0.0.1 keycloak.localhost` to
`/etc/hosts`.

The stack also runs a **Next.js demo** at <http://localhost:3000> that shows every
channel type, client events, encryption, user sign-in, channel queries, and webhooks.
Open it in two browsers with different names. See
[`examples/nextjs-demo`](examples/nextjs-demo/README.md).

A second Keycloak user, **outsider / outsider**, exists to show what a signed-in user
who is not on the admin allowlist sees (a 403 page).

## Configuration

Arc is configured entirely by environment variables and refuses to boot, naming the
variable, if a required one is missing.

| Variable | Required | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | Yes | `postgres://user:pass@host:5432/arc` |
| `SECRET_KEY_BASE` | Yes | Signs dashboard sessions and cookies (64 bytes) |
| `ARC_ENCRYPTION_KEY` | Yes | 32 bytes, base64. Encrypts secrets at rest. See the warning above |
| `PHX_HOST` | Yes | Public hostname, used in generated URLs and credential snippets |
| `PORT` | No | Listen port, default `4000` |
| `PHX_PUBLIC_PORT` | No | Public port shown in snippets and used in URLs, default `443` |
| `PHX_PUBLIC_SCHEME` | No | `https` (default) or `http` |
| `ARC_OIDC_ISSUER` | Yes | e.g. `https://keycloak.example.com/realms/arc` |
| `ARC_OIDC_CLIENT_ID` | Yes | Confidential client registered in Keycloak |
| `ARC_OIDC_CLIENT_SECRET` | Yes | That client's secret |
| `ARC_ADMIN_EMAILS` | Yes | Comma-separated allowlist; anyone else gets 403 after sign-in |
| `ARC_CLUSTER_STRATEGY` | No | `none` (default), `gossip`, or `dns` |
| `ARC_CLUSTER_DNS_QUERY` | If `dns` | Headless service name, e.g. `arc-headless.default.svc.cluster.local` |
| `RELEASE_COOKIE` | If clustered | Shared Erlang distribution cookie |
| `ARC_METRICS_AUTH_TOKEN` | No | If set, `/metrics` requires `Authorization: Bearer <token>` |
| `POOL_SIZE` | No | Postgres connection pool, default `10` |
| `ARC_MAX_CONNECTIONS_PER_NODE` | No | Safety ceiling per node, default unlimited |

Generate the two keys with:

```bash
mix arc.gen.keys
```

Migrations run automatically when the container starts, so a fresh Postgres plus the
container is a working install.

## Keycloak setup

1. Create a realm (for example `arc`).
2. Create a client with **Client authentication** on (confidential), and the valid
   redirect URI `https://<your Arc host>/auth/callback`. Add
   `https://<your Arc host>/*` as a valid post-logout redirect URI.
3. Under the client's capabilities, enable **Standard flow** and disable **Direct
   access grants**. Set PKCE to `S256`.
4. Copy the client secret from the **Credentials** tab into `ARC_OIDC_CLIENT_SECRET`.

Admins must have a verified email in Keycloak that appears in `ARC_ADMIN_EMAILS`.
There is one role; the allowlist is the whole authorization model, and removing an
email revokes access on the admin's next request. Sessions last 12 hours.

`docker/keycloak/arc-realm.json` is the realm used by `docker compose`; it is a working
example of the settings above.

If the identity provider is unreachable, only dashboard sign-in is affected: Arc keeps
serving connections and the API, shows a "not reachable" page at sign-in, and retries
the provider in the background.

## Using Arc from a browser and from Django

After creating an app, the dashboard prints both snippets with your values filled in.

**Browser** (`npm install pusher-js`, the protocol's JavaScript client SDK):

```js
import Pusher from "pusher-js";

const arc = new Pusher("<app key>", {
  wsHost: "arc.example.com",
  wsPort: 443,
  wssPort: 443,
  forceTLS: true,
  enabledTransports: ["ws", "wss"],
  cluster: "arc", // required by the SDK, ignored by Arc
  channelAuthorization: { endpoint: "/realtime/auth/", transport: "ajax" },
});

arc.subscribe("orders").bind("created", (order) => console.log(order));
```

**Django** (`pip install pusher`, the protocol's Python server SDK):

```python
# settings.py
ARC = {
    "app_id": "1",
    "key": "<app key>",
    "secret": "<app secret>",
    "host": "arc.example.com",
    "port": 443,
    "ssl": True,
}

# views.py
import pusher
from django.conf import settings
from django.http import JsonResponse

arc = pusher.Pusher(**settings.ARC)

def create_order(request):
    ...
    arc.trigger("orders", "created", {"id": order.id}, request.POST.get("socket_id"))

# The auth endpoint for private and presence channels.
def realtime_auth(request):
    channel = request.POST["channel_name"]
    socket_id = request.POST["socket_id"]
    custom = {"user_id": str(request.user.id), "user_info": {"name": request.user.get_full_name()}}
    data = custom if channel.startswith("presence-") else None
    return JsonResponse(arc.authenticate(channel=channel, socket_id=socket_id, custom_data=data))
```

For end-to-end encrypted channels, generate an encryption master key on the app's
page and pass it to the server SDK as `encryption_master_key_base64`. Arc never sees
plaintext for `private-encrypted-` channels.

## Protocol reference

WebSocket endpoint: `GET /app/<key>?protocol=7&client=<name>&version=<version>`.

### Channel types

| Prefix | Auth | Presence | Client events | Encrypted | Last event retained |
| --- | --- | --- | --- | --- | --- |
| *(none)* | No | No | No | No | No |
| `private-` | Yes | No | Yes | No | No |
| `private-encrypted-` | Yes | No | No | Yes | No |
| `presence-` | Yes | Yes | Yes | No | No |
| `cache-` | No | No | No | No | Yes |
| `private-cache-` | Yes | No | Yes | No | Yes |
| `presence-cache-` | Yes | Yes | Yes | No | Yes |
| `#server-to-user-<id>` | Signed-in user `<id>` only | No | No | No | No |

Channel names are at most 164 characters from `[A-Za-z0-9_\-=@,.;]`. Invalid names are
rejected, never normalised.

### Limits

| Limit | Default | Where to change |
| --- | --- | --- |
| Event payload (API) | 10 KB → HTTP 413 | App settings |
| Channels per publish | 100 | Fixed |
| Events per batch | 10 | Fixed |
| Presence members per channel | 100 → subscription error `LimitReached` (403) | App settings, or off |
| `channel_data` size | 10 KB | Fixed |
| Client events | 10 per second per connection, 10 KB each | Fixed |
| Connections per app | Unlimited | App settings |
| Connections per node | Unlimited | `ARC_MAX_CONNECTIONS_PER_NODE` |
| Inbound frame size | 256 KB → close 1009 | Config `max_frame_size` |
| Queued messages per connection | 5,000 → close 4102 | Config `max_queue_len` |
| Retained cache-channel event | 30 minutes, per node, lost on restart | Config `cache_ttl` |
| API requests per app per node | 10,000/s sustained, 20,000 burst → HTTP 429 | Config `api_rate`, `api_burst` |

### Error codes

SDKs act on the band, not the number.

| Code | Band | Closes | When |
| --- | --- | --- | --- |
| 4001 | Do not reconnect | Yes | Unknown app key, or the app was deleted |
| 4003 | Do not reconnect | Yes | App disabled |
| 4004 | Do not reconnect | Yes | App over its connection limit |
| 4007 | Do not reconnect | Yes | Protocol version other than 7 |
| 4008 | Do not reconnect | Yes | No protocol version |
| 4009 | Do not reconnect | Yes | User sign-in failed |
| 4100 | Reconnect after backoff | Yes | Node over capacity or still starting |
| 4101 | Reconnect after backoff | Yes | Node shutting down |
| 4102 | Reconnect after backoff | Yes | Client not reading fast enough |
| 4201 | Reconnect immediately | Yes | No pong after a server ping |
| 4300 | Do not retry | Yes | Connections terminated by the application (API) |
| 4301 | — | No | Client event over the rate limit |
| `null` | — | No | Malformed frame, unknown event, rejected client event |

Subscription failures are delivered on the channel as `pusher:subscription_error`
with `{"type", "error", "status"}`: 401 for a bad signature, 403 when the app forbids
it (for example a full presence channel), 400 for invalid input.

## HTTP API

Every request is signed: query parameters `auth_key`, `auth_timestamp`,
`auth_version=1.0`, `body_md5` (when there is a body), and `auth_signature`, the hex
HMAC-SHA256 with the app secret of `METHOD\npath\nsorted query`. Timestamps more than
600 seconds off are rejected. Errors are plain text written for the developer.

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/apps/:app_id/events` | Publish one event to up to 100 channels |
| POST | `/apps/:app_id/batch_events` | Publish up to 10 events |
| GET | `/apps/:app_id/channels` | Occupied channels (`filter_by_prefix`, `info`) |
| GET | `/apps/:app_id/channels/:name` | `occupied`, plus `user_count` / `subscription_count` on request |
| GET | `/apps/:app_id/channels/:name/users` | Presence member ids |
| POST | `/apps/:app_id/users/:user_id/terminate_connections` | Close every connection signed in as the user |
| POST | `/users/:user_id/terminate_connections` | The same, app identified by `auth_key` |

`user_count` is only valid for presence channels (400 otherwise).
`subscription_count` requires the app setting of the same name (403 otherwise),
because it costs a cluster-wide count.

## Webhooks

Configure endpoints per app in the dashboard. Arc posts
`{"time_ms": ..., "events": [...]}` with events that happened within a short window
batched into one request.

| Event | Fires when |
| --- | --- |
| `channel_occupied` | The first subscriber in the cluster joins |
| `channel_vacated` | The last subscriber leaves (held 2 s; cancelled if someone rejoins) |
| `member_added` | A user id joins a presence channel for the first time |
| `member_removed` | A user id's last connection leaves (held 2 s, same rule) |
| `client_event` | A client event is published, for endpoints that opt in |
| `cache_miss` | A cache channel is subscribed to with nothing retained |

Headers: `X-Pusher-Key` (app key) and `X-Pusher-Signature` (hex HMAC-SHA256 of the raw
body with the app secret), which the server SDKs' `validate_webhook` checks. An
endpoint may also have its own secret, sent as `X-Arc-Signature`.

Delivery: 10-second timeout. 5xx responses and timeouts are retried after 1 s, 5 s,
30 s, 2 min, and 10 min, then marked failed; 4xx responses are not retried. Every
attempt is recorded and visible in the dashboard. Deliveries survive a node restart
and are pruned after 7 days.

## Operations

**TLS** is expected to terminate at a proxy in front of Arc. The proxy must forward
WebSocket upgrades, for example with nginx:

```nginx
location / {
  proxy_pass http://arc;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
  proxy_set_header Host $host;
  proxy_read_timeout 300s;
}
```

**File descriptors.** Every connection is a socket. Raise the limit to at least
65,536 (`ulimit -n`, or `ulimits.nofile` in compose) for meaningful connection counts.

**VM flags** live in `rel/vm.args.eex`: `+P` and `+Q` (process and port ceilings) are
set well above a million, `+K true` enables kernel polling, and `+sbwt none` (with
the `dcpu`/`dio` variants) stops idle schedulers from spinning, which otherwise shows
up as phantom CPU in containers.

**Health.** `/health/live` returns 200 while the VM runs. `/health/ready` returns 200
only after migrations are applied and the app cache is warm; point load balancers and
Kubernetes readiness probes at it.

**Metrics.** `/metrics` serves Prometheus text: `arc_connections_active`,
`arc_connections_total`, `arc_connection_duration_seconds`, `arc_channels_occupied`,
`arc_subscriptions_active`, `arc_messages_sent_total`, `arc_messages_received_total`,
`arc_broadcast_duration_seconds`, `arc_api_requests_total`,
`arc_api_request_duration_seconds`, `arc_auth_failures_total`,
`arc_webhook_deliveries_total`, `arc_webhook_queue_depth`, `arc_presence_members`,
`arc_rate_limit_hits_total`, and BEAM metrics (memory by type, run queues, process
counts, scheduler utilisation). No metric is labelled with a channel, socket, or user.
Run queue length is the first number to move when a node is in trouble; binary memory
is where leaks show.

**Clustering.** Set `ARC_CLUSTER_STRATEGY=gossip` (Docker networks) or `dns`
(Kubernetes, with a headless service in `ARC_CLUSTER_DNS_QUERY`), and the same
`RELEASE_COOKIE` on every node. Publishes fan out across nodes; presence converges
after a partition; a node that dies has its members removed within about 5 seconds.
Rate limits and cache-channel retention are per node.

**Creating apps from a shell** on a running node:

```bash
bin/arc rpc 'IO.puts(Jason.encode!(Arc.Release.create_app("Chat")))'
```

**Logs** are JSON in production. Auth failures are logged at info with the app id and
reason; secrets, signatures, and payloads are never logged.

## Releases

Tagging a version builds the release image for `linux/amd64` and `linux/arm64` and
pushes it to Docker Hub as `kryptonhq/arc:<version>` and `kryptonhq/arc:latest`:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

`Actions -> Publish image -> Run workflow` publishes an arbitrary tag (for example
`edge`) from the current branch. Both paths start the pushed image against a throwaway
Postgres and wait for `/health/ready` before finishing, so a broken image fails the
run rather than sitting on Docker Hub.

The workflow needs two repository secrets: `DOCKERHUB_USERNAME`, a Docker Hub account
with push access to `kryptonhq/arc`, and `DOCKERHUB_TOKEN`, an access token for it
(Docker Hub → Account settings → Personal access tokens), not the account password.

Running a published image:

```bash
docker run -p 4000:4000 \
  -e DATABASE_URL=postgres://arc:arc@db:5432/arc \
  -e SECRET_KEY_BASE=... -e ARC_ENCRYPTION_KEY=... -e PHX_HOST=arc.example.com \
  -e ARC_OIDC_ISSUER=... -e ARC_OIDC_CLIENT_ID=... -e ARC_OIDC_CLIENT_SECRET=... \
  -e ARC_ADMIN_EMAILS=you@example.com \
  kryptonhq/arc:latest
```

## Development

```bash
docker compose up -d postgres keycloak   # dependencies
mix setup                                # deps, database, assets
mix phx.server                           # http://localhost:4000
```

Tests:

```bash
mix test                          # unit, property, protocol conformance, failure tests
mix coveralls                     # the same, failing below 90% coverage
mix test --only cluster           # three-node cluster
test/integration/run.sh           # real client (JavaScript) and server (Python) SDKs
```

Load tests live in [`loadtest/`](loadtest/README.md).

## License

Apache License 2.0. See [LICENSE](LICENSE).
