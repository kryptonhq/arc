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
  # Per-app HTTP API token bucket: sustained requests per second and burst.
  api_rate: 10_000,
  api_burst: 20_000

config :arc, Arc.Webhooks,
  # Events occurring within this window (ms) are sent in one request.
  batch_window: 250,
  # vacated / member_removed are held this long (ms) and cancelled if the channel refills.
  debounce_ms: 2_000,
  # Seconds between attempts after a retryable failure; exhausted = failed.
  retry_schedule: [1, 5, 30, 120, 600],
  request_timeout: 10_000,
  poll_interval: 1_000,
  retention_days: 7

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
