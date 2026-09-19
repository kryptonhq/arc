defmodule Arc.Webhooks.Delivery do
  @moduledoc """
  One webhook request and its retry state. `status` moves through
  `pending` → `in_flight` → `delivered` | `pending` (retry) | `failed`.
  """
  use Ecto.Schema

  schema "webhook_deliveries" do
    belongs_to :endpoint, Arc.Webhooks.Endpoint
    belongs_to :app, Arc.Apps.App
    field :payload, :map
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :next_attempt_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
