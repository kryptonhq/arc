defmodule Arc.Audit do
  @moduledoc "Append-only record of administrative actions."
  import Ecto.Query

  alias Arc.Repo
  alias Arc.Audit.Entry
  alias Arc.Admin.AdminUser

  @doc "Writes an audit row. `actor` is the admin user, or nil for system/console actions."
  def log(actor, action, app_id, metadata \\ %{}) do
    %Entry{
      admin_user_id: actor_id(actor),
      action: action,
      app_id: app_id,
      metadata: metadata
    }
    |> Repo.insert()
  end

  @doc "Newest entries first, with the admin preloaded."
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    from(e in Entry,
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^limit,
      offset: ^offset,
      preload: [:admin_user]
    )
    |> maybe_filter_app(Keyword.get(opts, :app_id))
    |> Repo.all()
  end

  defp maybe_filter_app(query, nil), do: query
  defp maybe_filter_app(query, app_id), do: where(query, [e], e.app_id == ^app_id)

  defp actor_id(%AdminUser{id: id}), do: id
  defp actor_id(_), do: nil
end
