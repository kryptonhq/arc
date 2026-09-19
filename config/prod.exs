import Config

# Digested static assets, produced by `mix assets.deploy` during the release build.
config :arc, ArcWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# TLS is terminated at the proxy in front of Arc (see README, "Operations"), so the
# endpoint does not force SSL itself; health checks and in-cluster traffic stay plain HTTP.

config :logger, level: :info

# Structured JSON logs in production.
config :logger, :default_handler,
  formatter: {LoggerJSON.Formatters.Basic, metadata: [:request_id, :app_id]}
