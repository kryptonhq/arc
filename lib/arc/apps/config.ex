defmodule Arc.Apps.Config do
  @moduledoc """
  The in-memory, decrypted view of an app that the data plane reads on every
  handshake, subscription, and API call. Built from `Arc.Apps.App` and held in
  `Arc.Apps.Cache`; never read from Postgres on the hot path.
  """

  @enforce_keys [:id, :key, :secret]
  defstruct [
    :id,
    :name,
    :key,
    :secret,
    :encryption_master_key,
    :max_connections,
    enabled: true,
    client_events_enabled: false,
    enable_presence_limits: true,
    max_presence_members: 100,
    max_payload_bytes: 10_240,
    subscription_count_enabled: false,
    # Active webhook endpoints: [%{id, url, secret, events: MapSet}]
    webhooks: [],
    version: 0
  ]

  @type t :: %__MODULE__{}

  @doc "Builds a config from a loaded app record."
  def from_app(%Arc.Apps.App{} = app) do
    %__MODULE__{
      id: app.id,
      name: app.name,
      key: app.key,
      secret: app.secret,
      encryption_master_key: app.encryption_master_key,
      enabled: app.enabled,
      client_events_enabled: app.client_events_enabled,
      enable_presence_limits: app.enable_presence_limits,
      max_presence_members: app.max_presence_members,
      max_connections: app.max_connections,
      max_payload_bytes: app.max_payload_bytes,
      subscription_count_enabled: app.subscription_count_enabled,
      webhooks: webhooks(app),
      version: version(app.updated_at)
    }
  end

  @doc "True if any active endpoint of the app wants `event`."
  def webhook_enabled?(%__MODULE__{webhooks: webhooks}, event),
    do: Enum.any?(webhooks, &MapSet.member?(&1.events, event))

  defp webhooks(%Arc.Apps.App{webhook_endpoints: endpoints}) when is_list(endpoints) do
    for endpoint <- endpoints, endpoint.active do
      %{
        id: endpoint.id,
        url: endpoint.url,
        secret: endpoint.secret,
        events: MapSet.new(endpoint.events)
      }
    end
  end

  defp webhooks(_app), do: []

  defp version(nil), do: 0
  defp version(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

  defimpl Inspect do
    def inspect(config, _opts) do
      "#Arc.Apps.Config<id: #{config.id}, key: #{config.key}, secret: **redacted**>"
    end
  end
end
