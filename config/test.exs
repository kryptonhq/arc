import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :arc, Arc.Repo,
  url:
    System.get_env("TEST_DATABASE_URL", "postgres://arc:arc@localhost:5442/arc_test") <>
      "#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :arc, ArcWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  url: [host: "localhost", port: 4002],
  secret_key_base: "tIn4HAFhbUM+athCpjoHwMm8GSHWzzzls8LaZd1EllDYiF4dlAK4yvb5f9BjdTkF",
  server: true

config :arc, Arc.Realtime,
  activity_timeout: 120,
  pong_timeout: 30_000,
  idle_check_interval: 5_000,
  # Every test connects from one address; the limit is exercised by lowering it.
  connect_rate_per_minute: 1_000_000

# Tests drive the database check explicitly with Arc.Health.check_db_now/0.
config :arc, Arc.Health, db_check_interval: nil

# No waiting for a load balancer in tests.
config :arc, :drain_seconds, 0

# The dashboard's live numbers are driven by tests, not by the clock.
config :arc, Arc.Metrics, interval: 60_000

config :arc, Arc.Webhooks,
  batch_window: 20,
  debounce_ms: 200,
  retry_schedule: [10, 20, 30, 40, 50],
  poll_interval: 50,
  scheduler: false

config :arc, :oidc_adapter, Arc.Test.FakeOIDC

config :arc, :oidc,
  issuer: "http://localhost:8180/realms/arc",
  client_id: "arc-dashboard",
  client_secret: "test-secret",
  admin_emails: ["admin@example.com"]

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
