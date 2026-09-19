defmodule Arc.Webhooks.Endpoint do
  @moduledoc "A URL that receives webhook batches for an app."
  use Ecto.Schema
  import Ecto.Changeset

  @event_types ~w(channel_occupied channel_vacated member_added member_removed client_event cache_miss)

  schema "webhook_endpoints" do
    belongs_to :app, Arc.Apps.App
    field :url, :string
    field :secret, Arc.Encrypted.Binary, redact: true
    field :events, {:array, :string}, default: []
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  def event_types, do: @event_types

  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [:url, :secret, :events, :active])
    |> update_change(:url, &String.trim/1)
    |> update_change(:events, fn events -> events |> Enum.reject(&(&1 == "")) |> Enum.uniq() end)
    |> validate_required([:url])
    |> validate_length(:url, max: 2048)
    |> validate_change(:url, &validate_url/2)
    |> validate_subset(:events, @event_types)
    |> validate_events_present()
  end

  defp validate_events_present(changeset) do
    case get_field(changeset, :events) do
      [_ | _] -> changeset
      _ -> add_error(changeset, :events, "select at least one event type")
    end
  end

  defp validate_url(:url, url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        []

      _ ->
        [url: "must be an http or https URL"]
    end
  end
end
