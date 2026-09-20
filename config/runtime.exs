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
    nil ->
      default

    "" ->
      default

    value ->
      case Integer.parse(value) do
        {int, ""} -> int
        _ -> raise "environment variable #{name} must be an integer (got #{inspect(value)})"
      end
  end
end

# Only settings that are actually set in the environment are applied, so the
# defaults in config.exs (and the overrides in test.exs) stay in force otherwise.
env_ints = fn pairs ->
  for {key, name} <- pairs, value = optional_int.(name, nil), not is_nil(value), do: {key, value}
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

decode_key = fn name, value ->
  case Base.decode64(value) do
    {:ok, <<_::binary-size(32)>> = bytes} ->
      bytes

    _ ->
      raise "#{name} must be 32 bytes, base64 encoded. Generate one with `mix arc.gen.keys`."
  end
end

encryption_key_bytes = decode_key.("ARC_ENCRYPTION_KEY", encryption_key)

# Previous keys, still able to decrypt, while `mix arc.rewrap` moves rows to the
# current key. See Arc.Vault.Cipher.
retired_keys =
  System.get_env("ARC_ENCRYPTION_KEY_RETIRED", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.map(&decode_key.("ARC_ENCRYPTION_KEY_RETIRED", &1))

config :arc, Arc.Vault,
  ciphers: [
    default:
      {Arc.Vault.Cipher,
       tag: "AES.GCM.V1", key: encryption_key_bytes, retired_keys: retired_keys, iv_length: 12}
  ]

config :arc,
       Arc.Realtime,
       [max_connections_per_node: optional_int.("ARC_MAX_CONNECTIONS_PER_NODE", nil)] ++
         env_ints.(
           activity_timeout: "ARC_ACTIVITY_TIMEOUT",
           pong_timeout: "ARC_PONG_TIMEOUT_MS",
           max_queue_len: "ARC_MAX_QUEUE_LEN",
           max_frame_size: "ARC_MAX_FRAME_SIZE",
           client_event_rate: "ARC_CLIENT_EVENT_RATE",
           api_rate: "ARC_API_RATE",
           api_burst: "ARC_API_BURST",
           connect_rate_per_minute: "ARC_CONNECT_RATE_PER_MINUTE",
           subscribe_rate: "ARC_SUBSCRIBE_RATE",
           auth_failure_limit: "ARC_AUTH_FAILURE_LIMIT",
           cache_ttl: "ARC_CACHE_TTL_MS"
         )

config :arc, :metrics_auth_token, System.get_env("ARC_METRICS_AUTH_TOKEN")

config :arc, :drain_seconds, optional_int.("ARC_DRAIN_SECONDS", 5)

config :arc,
       :trusted_proxies,
       ArcWeb.Plugs.ClientIp.parse_cidrs(System.get_env("ARC_TRUSTED_PROXIES", ""))

if config_env() == :dev do
  # Plain http on localhost in development.
  config :arc, :secure_cookies, false
end

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

  if byte_size(secret_key_base) < 64 do
    raise "SECRET_KEY_BASE must be at least 64 bytes. Generate one with `mix arc.gen.keys`."
  end

  admin_email_list =
    admin_emails |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  for email <- admin_email_list, not String.contains?(email, "@") do
    raise "ARC_ADMIN_EMAILS must be a comma-separated list of email addresses (got #{inspect(email)})"
  end

  public_scheme = System.get_env("PHX_PUBLIC_SCHEME", "https")

  if public_scheme not in ["http", "https"] do
    raise "PHX_PUBLIC_SCHEME must be http or https (got #{inspect(public_scheme)})"
  end

  # The dashboard cookie is only sent over TLS unless this install is explicitly http.
  config :arc, :secure_cookies, public_scheme == "https"

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :arc, Arc.Repo,
    url: database_url,
    pool_size: optional_int.("POOL_SIZE", 10),
    socket_options: maybe_ipv6

  config :arc, ArcWeb.Endpoint,
    url: [
      host: host,
      port: optional_int.("PHX_PUBLIC_PORT", 443),
      scheme: public_scheme
    ],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base

  config :arc, :oidc,
    issuer: oidc_issuer,
    client_id: oidc_client_id,
    client_secret: oidc_client_secret,
    admin_emails: admin_email_list

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
