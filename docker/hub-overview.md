# Arc

Arc is a self-hosted realtime messaging server: persistent WebSocket connections,
channel-based pub/sub, presence, and a signed HTTP API that application backends call
to publish events.

Arc speaks the **Channels protocol, version 7**, so existing client SDKs for that
protocol (JavaScript, iOS, Android, Flutter) and the Python server SDK used from
Django work against it by changing the host and credentials only.

- Source, issues and full documentation: <https://github.com/kryptonhq/arc>
- Licence: Apache-2.0

## Tags

| Tag | What it is |
| --- | --- |
| `latest` | The most recent release |
| `0.1.0`, `0.2.0`, … | A specific release. Pin this in production |

Each tag is a multi-architecture image for `linux/amd64` and `linux/arm64`, and is
started against a throwaway Postgres in CI before publishing, so a tag that exists
has booted at least once.

## Running it

Arc needs Postgres and an OpenID Connect provider for dashboard sign-in. Migrations
run automatically at startup, so a fresh database plus this image is a working install.

```bash
docker run -p 4000:4000 \
  -e DATABASE_URL=postgres://arc:arc@postgres:5432/arc \
  -e SECRET_KEY_BASE=$(openssl rand -base64 48 | head -c 64) \
  -e ARC_ENCRYPTION_KEY=$(openssl rand -base64 32) \
  -e PHX_HOST=arc.example.com \
  -e ARC_OIDC_ISSUER=https://keycloak.example.com/realms/arc \
  -e ARC_OIDC_CLIENT_ID=arc-dashboard \
  -e ARC_OIDC_CLIENT_SECRET=... \
  -e ARC_ADMIN_EMAILS=you@example.com \
  kryptonhq/arc:latest
```

For a complete local stack — Arc, Postgres, a pre-configured Keycloak, and a Next.js
demo app — clone the repository and run `docker compose up`.

**Keep `ARC_ENCRYPTION_KEY` safe and backed up.** It encrypts every app secret,
encryption master key and webhook secret at rest. If it is lost, those secrets cannot
be recovered and every app must be issued new credentials.

## Configuration

| Variable | Required | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | Yes | `postgres://user:pass@host:5432/arc` |
| `SECRET_KEY_BASE` | Yes | Signs dashboard sessions and cookies (64 bytes) |
| `ARC_ENCRYPTION_KEY` | Yes | 32 bytes, base64. Encrypts secrets at rest |
| `PHX_HOST` | Yes | Public hostname, used in generated URLs and credential snippets |
| `ARC_OIDC_ISSUER`, `ARC_OIDC_CLIENT_ID`, `ARC_OIDC_CLIENT_SECRET` | Yes | Dashboard sign-in |
| `ARC_ADMIN_EMAILS` | Yes | Comma-separated allowlist of administrators |
| `PORT` | No | Listen port, default `4000` |
| `ARC_CLUSTER_STRATEGY` | No | `none` (default), `gossip`, or `dns`, with `RELEASE_COOKIE` shared between nodes |
| `ARC_METRICS_AUTH_TOKEN` | No | If set, `/metrics` requires this bearer token |

The full list, including cluster and limit settings, is in the repository README.

## Health and metrics

- `GET /health/live` — 200 while the VM is running
- `GET /health/ready` — 200 once migrations are applied and the app cache is warm
- `GET /metrics` — Prometheus text format

TLS is expected to terminate at a proxy in front of Arc, which must forward WebSocket
upgrade headers.
