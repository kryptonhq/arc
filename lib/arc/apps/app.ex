defmodule Arc.Apps.App do
  @moduledoc """
  An application: the unit of isolation for connections, channels, and credentials.

  `id` is the numeric app id that server SDKs put in API paths, `key` is the public key
  clients connect with, and `secret` signs everything. The secret and the optional
  encryption master key are encrypted at rest.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "apps" do
    field :name, :string
    field :key, :string
    field :secret, Arc.Encrypted.Binary, redact: true
    field :encryption_master_key, Arc.Encrypted.Binary, redact: true
    field :enabled, :boolean, default: true
    field :client_events_enabled, :boolean, default: false
    field :enable_presence_limits, :boolean, default: true
    field :max_presence_members, :integer, default: 100
    field :max_connections, :integer
    field :max_payload_bytes, :integer, default: 10_240
    field :subscription_count_enabled, :boolean, default: false

    has_many :webhook_endpoints, Arc.Webhooks.Endpoint

    timestamps()
  end

  @settings ~w(name enabled client_events_enabled enable_presence_limits max_presence_members
               max_connections max_payload_bytes subscription_count_enabled)a

  @doc "Changeset for the admin-editable settings. Credentials are never cast from input."
  def settings_changeset(app, attrs) do
    app
    |> cast(attrs, @settings)
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_number(:max_presence_members, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:max_connections, greater_than: 0)
    |> validate_number(:max_payload_bytes,
      greater_than_or_equal_to: 1_024,
      less_than_or_equal_to: 10_485_760
    )
  end

  @doc false
  def credentials_changeset(app, attrs) do
    app
    |> cast(attrs, [:key, :secret])
    |> validate_required([:key, :secret])
    |> unique_constraint(:key)
  end

  @doc false
  def master_key_changeset(app, master_key) do
    app
    |> change(encryption_master_key: master_key)
    |> validate_change(:encryption_master_key, fn _, value ->
      case value do
        nil -> []
        <<_::binary-size(32)>> -> []
        _ -> [encryption_master_key: "must be 32 bytes"]
      end
    end)
  end
end
