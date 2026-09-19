defmodule Arc.Admin.AdminUser do
  @moduledoc "A dashboard administrator, created on first sign-in from the OIDC allowlist."
  use Ecto.Schema

  schema "admin_users" do
    field :email, :string
    field :subject, :string
    field :last_login_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
