import Config

# Runtime configuration, evaluated on boot in every environment including releases.
#
# The environment variable contract is documented in README.md. In production every
# required variable is checked up front so a missing one fails the boot with its name,
# instead of surfacing later as a nil somewhere in the data plane.

required = fn name ->
  case System.get_env(name) do
    value when is_binary(value) and value != "" ->
      value

    _ ->
      raise """
      environment variable #{name} is missing.
      Arc will not boot without it. See README.md, "Configuration".
      """
  end
end

optional_int = fn name, default ->
  case System.get_env(name) do
    nil -> default
    "" -> default
    value -> String.to_integer(value)
  end
end

if System.get_env("PHX_SERVER") do
  config :arc, ArcWeb.Endpoint, server: true
end

if config_env() != :test do
  config :arc, ArcWeb.Endpoint, http: [port: optional_int.("PORT", 4000)]
end

# Encryption key for secrets at rest. Development and test use a fixed key so a fresh
# checkout works; production must supply its own.
encryption_key =
  if config_env() == :prod do
    required.("ARC_ENCRYPTION_KEY")
  else
    System.get_env("ARC_ENCRYPTION_KEY", "ZGV2LW9ubHktZW5jcnlwdGlvbi1rZXktMzJieXRlcyE=")
  end

encryption_key_bytes =
  case Base.decode64(encryption_key) do
    {:ok, <<_::binary-size(32)>> = bytes} ->
      bytes

    _ ->
      raise "ARC_ENCRYPTION_KEY must be 32 bytes, base64 encoded. Generate one with `mix arc.gen.keys`."
  end

config :arc, Arc.Vault,
  ciphers: [
    default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: encryption_key_bytes, iv_length: 12}
  ]

config :arc, Arc.Realtime,
  max_connections_per_node:
    (case System.get_env("ARC_MAX_CONNECTIONS_PER_NODE") do
       nil -> nil
       "" -> nil
       value -> String.to_integer(value)
     end)

config :arc, :metrics_auth_token, System.get_env("ARC_METRICS_AUTH_TOKEN")

if config_env() == :dev do
  config :arc, :oidc,
    issuer: System.get_env("ARC_OIDC_ISSUER", "http://localhost:8180/realms/arc"),
    client_id: System.get_env("ARC_OIDC_CLIENT_ID", "arc-dashboard"),
    client_secret: System.get_env("ARC_OIDC_CLIENT_SECRET", "arc-dashboard-dev-secret"),
    admin_emails:
      System.get_env("ARC_ADMIN_EMAILS", "admin@example.com")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
end

if config_env() == :prod do
  database_url = required.("DATABASE_URL")
  secret_key_base = required.("SECRET_KEY_BASE")
  host = required.("PHX_HOST")
  oidc_issuer = required.("ARC_OIDC_ISSUER")
  oidc_client_id = required.("ARC_OIDC_CLIENT_ID")
  oidc_client_secret = required.("ARC_OIDC_CLIENT_SECRET")
  admin_emails = required.("ARC_ADMIN_EMAILS")

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :arc, Arc.Repo,
    url: database_url,
    pool_size: optional_int.("POOL_SIZE", 10),
    socket_options: maybe_ipv6

  config :arc, ArcWeb.Endpoint,
    url: [
      host: host,
      port: optional_int.("PHX_PUBLIC_PORT", 443),
      scheme: System.get_env("PHX_PUBLIC_SCHEME", "https")
    ],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base

  config :arc, :oidc,
    issuer: oidc_issuer,
    client_id: oidc_client_id,
    client_secret: oidc_client_secret,
    admin_emails: admin_emails |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  cluster_topologies =
    case System.get_env("ARC_CLUSTER_STRATEGY", "none") do
      "none" ->
        []

      "gossip" ->
        required.("RELEASE_COOKIE")
        [arc: [strategy: Cluster.Strategy.Gossip]]

      "dns" ->
        required.("RELEASE_COOKIE")

        [
          arc: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              polling_interval: 5_000,
              query: required.("ARC_CLUSTER_DNS_QUERY"),
              node_basename: System.get_env("RELEASE_NAME", "arc")
            ]
          ]
        ]

      other ->
        raise "ARC_CLUSTER_STRATEGY must be one of none, gossip, dns (got #{inspect(other)})"
    end

  config :libcluster, topologies: cluster_topologies
end
