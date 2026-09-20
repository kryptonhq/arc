# Contributing to Arc

Thanks for taking an interest. This page covers getting the server running, what CI
asks of a change, and how a change reaches `main`.

## Getting set up

```bash
docker compose up -d postgres keycloak   # dependencies
mix setup                                # deps, database, assets
mix phx.server                           # http://localhost:4000
```

Arc is developed against Elixir 1.18 and OTP 27, which is what CI and the container
image use. Newer versions generally work locally; anything that depends on them will
fail the build, so keep syntax and standard-library use within 1.18.

## Running the tests

```bash
mix test                          # unit, property, protocol conformance, failure tests
mix coveralls                     # the same, failing below 90% coverage
mix test.cluster                  # three nodes (starts the VM with partition policing off)
test/integration/run.sh           # real client (JavaScript) and server (Python) SDKs
```

`mix test.cluster` starts the VM with OTP's overlapping-partition protection off,
because one of the tests cuts the cluster in half on purpose. Running those tests
through plain `mix test` will fail with an explanation rather than a mystery.

Load tests in [`loadtest/`](loadtest/README.md) are run by hand, not by CI.

## What CI checks

Every pull request must pass:

| Check | What it covers |
| --- | --- |
| Unit, property, protocol, failure | The suite, formatting, `--warnings-as-errors`, and coverage |
| Cluster (three nodes) | Publish, presence, and connection termination across nodes |
| Real SDKs | The JavaScript client and Python server SDKs against a running Arc |
| Compose stack boots | The container image, the demo app, health and metrics endpoints |
| Documentation site builds | `website/` compiles |
| Dependency review | No new dependency whose licence Arc cannot take on under Apache-2.0 |

Each job runs only when a change can affect it — a README edit does not start the
cluster tests — but every job reports either way, so the set of checks is the same
whichever path a pull request takes.

Coverage has a floor of 90%, and these modules must stay at 100%: `Arc.Crypto`,
`Arc.Crypto.SecretBox`, `Arc.Channels.Auth`, `Arc.Channels.Channel`,
`Arc.Realtime.Protocol`, `Arc.Realtime.Socket`, `Arc.Realtime.ErrorCodes`,
`ArcWeb.Plugs.ApiAuth`, and `ArcWeb.AdminAuth`. They decide who may connect, what they
may read, and what goes out on the wire; a line without a test is a line nobody has
checked.

## Protocol changes

Arc implements the Channels protocol, version 7, and its wire format is fixed by the
clients that speak it. A change to frame names, error codes, or authentication strings
breaks existing SDKs, so it needs a protocol conformance test showing the new
behaviour is what the clients expect — not what would be tidier.

## Opening a pull request

`main` is protected: it takes no direct pushes, from anyone. Branch, open a pull
request, and let the checks run.

- Write the commit subject as what the change does to Arc, in the present tense.
- Explain in the body why the change is needed. The diff already says what it does.
- Keep unrelated changes in separate pull requests.
- New dependencies need a reason and a licence compatible with Apache-2.0. Record
  anything notable in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Reporting a security issue

Please do not open a public issue for a vulnerability. Report it privately to the
maintainers instead, and give them time to publish a fix before describing it in
public.

## Licence

Contributions are accepted under the [Apache License 2.0](LICENSE), the licence Arc
ships under.
