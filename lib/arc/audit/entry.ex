defmodule Arc.Audit.Entry do
  @moduledoc false
  use Ecto.Schema

  schema "audit_log" do
    belongs_to :admin_user, Arc.Admin.AdminUser
    field :action, :string
    field :app_id, :integer
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
