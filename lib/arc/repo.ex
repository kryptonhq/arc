defmodule Arc.Repo do
  use Ecto.Repo,
    otp_app: :arc,
    adapter: Ecto.Adapters.Postgres
end
