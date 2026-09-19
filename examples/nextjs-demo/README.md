# Arc Next.js demo

A small Next.js app wired to a local Arc to show what it does. It uses the unmodified
Channels protocol v7 SDKs: `pusher-js` in the browser and the `pusher` Node server SDK
in route handlers.

| Panel | Arc feature | Where |
| --- | --- | --- |
| Chat | Public channel, server publish, `socket_id` exclusion | `app/api/messages` |
| Typing indicator | Client events on a presence channel | `components/Demo.jsx` |
| Who's here | Presence channel with member info | `app/api/auth/channel` |
| Current status | Cache channel: last event replayed to new subscribers, `cache_miss` | `app/api/status` |
| Encrypted notes | End-to-end encrypted channel (server encrypts, browser decrypts) | `app/api/secret` |
| Users | User sign-in, send to one user, terminate a user's connections | `app/api/auth/user`, `notify`, `kick` |
| Occupied channels | HTTP API channel queries with `user_count` | `app/api/channels` |
| Webhooks received | Signed webhooks, verified with the server SDK | `app/api/webhooks` |

## With the compose stack

```bash
docker compose up --build
```

Open <http://localhost:3000> in two browsers (or one normal and one private window)
and give each a different name. The `arc-seed` step creates the "Next.js demo" app
in Arc on first boot (with client events, an encryption master key, and a webhook
pointing at this app) and hands its credentials to the demo through a shared volume.
The app also appears in the Arc dashboard at <http://localhost:4000>.

## Running it on its own

Against an Arc on `localhost:4000`, with an app that has client events enabled and an
encryption master key:

```bash
npm install
ARC_APP_ID=... ARC_APP_KEY=... ARC_APP_SECRET=... ARC_MASTER_KEY=... npm run dev
```

Webhooks only arrive if Arc can reach this app; add an endpoint pointing at
`http://<reachable host>:3000/api/webhooks` in the Arc dashboard.

| Variable | Default | Purpose |
| --- | --- | --- |
| `ARC_CREDENTIALS_FILE` | — | JSON file with `id`, `key`, `secret`, `encryption_master_key` (used by compose) |
| `ARC_APP_ID`, `ARC_APP_KEY`, `ARC_APP_SECRET`, `ARC_MASTER_KEY` | — | Credentials, if no file |
| `ARC_API_HOST`, `ARC_API_PORT`, `ARC_API_TLS` | `localhost`, `4000`, `false` | Where the server calls Arc's HTTP API |
| `ARC_WS_HOST`, `ARC_WS_PORT`, `ARC_WS_TLS` | `localhost`, `4000`, `false` | Where browsers open the WebSocket |

The secret never reaches the browser: the page passes only the key and host to the
client, and all signing happens in route handlers.
