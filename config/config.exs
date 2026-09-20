# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :arc,
  ecto_repos: [Arc.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

# Data plane defaults. Every value here can be overridden per environment.
config :arc, Arc.Realtime,
  # Seconds advertised to clients in the connection handshake.
  activity_timeout: 120,
  # How long to wait for a pong after a server-initiated ping.
  pong_timeout: 30_000,
  # How often a socket checks whether it has gone idle.
  idle_check_interval: 15_000,
  # A socket whose mailbox grows past this is closed rather than allowed to grow unbounded.
  max_queue_len: 5_000,
  # Client event limits, per connection.
  client_event_rate: 10,
  client_event_max_bytes: 10_240,
  # Maximum inbound WebSocket frame size in bytes.
  max_frame_size: 262_144,
  max_connections_per_node: nil,
  # Per-app HTTP API token bucket: sustained requests per second and burst. Low enough
  # to actually fire when a backend loops; raise it per deployment if you publish more.
  api_rate: 1_000,
  api_burst: 2_000,
  # Per client address: WebSocket connection attempts per minute (and burst).
  connect_rate_per_minute: 120,
  # Per connection: subscribe attempts per second (and burst).
  subscribe_rate: 20,
  # Per connection: authorisation failures per minute before the connection is closed.
  auth_failure_limit: 10

# Readiness: how often the node confirms Postgres is reachable (ms).
config :arc, Arc.Health, db_check_interval: 5_000

# Seconds between readiness reporting 503 and client connections being closed on
# shutdown, so the load balancer stops routing here first.
config :arc, :drain_seconds, 5

# CIDRs whose X-Forwarded-For header is believed. Empty: the header is ignored.
config :arc, :trusted_proxies, []

# The dashboard session cookie carries the Secure flag; runtime.exs turns it off only
# for an install that is explicitly plain http.
config :arc, :secure_cookies, true

config :arc, Arc.Webhooks,
  # Events occurring within this window (ms) are sent in one request.
  batch_window: 250,
  # vacated / member_removed are held this long (ms) and cancelled if the channel refills.
  debounce_ms: 2_000,
  # Seconds between attempts after a retryable failure; exhausted = failed. The sum
  # is a little over an hour, so an endpoint down for 30 minutes still gets everything.
  retry_schedule: [1, 5, 30, 120, 600, 1_200, 1_800],
  request_timeout: 10_000,
  poll_interval: 1_000,
  retention_days: 7,
  # Deliveries in flight at once per node. Bounds the Postgres connections and
  # outbound sockets a retry storm can hold.
  max_concurrency: 20

config :libcluster, topologies: []

# Configure the endpoint
config :arc, ArcWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ArcWeb.ErrorHTML, json: ArcWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Arc.PubSub,
  live_view: [signing_salt: "UsqsqYFW"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  arc: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  arc: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
