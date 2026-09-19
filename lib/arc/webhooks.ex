defmodule Arc.Webhooks do
  @moduledoc """
  Webhook endpoints and the delivery log.

  Endpoint changes are audited and republish the app's config, which carries the
  active endpoints, so the data plane decides whether an event is wanted without a
  database read.
  """
  import Ecto.Query

  alias Arc.{Apps, Audit, Repo}
  alias Arc.Apps.App
  alias Arc.Webhooks.{Delivery, Endpoint}

  defdelegate event_types, to: Endpoint

  def list_endpoints(app_id) do
    Repo.all(from e in Endpoint, where: e.app_id == ^app_id, order_by: [asc: e.id])
  end

  def get_endpoint!(app_id, id), do: Repo.get_by!(Endpoint, app_id: app_id, id: id)

  def change_endpoint(endpoint \\ %Endpoint{}, attrs \\ %{}),
    do: Endpoint.changeset(endpoint, attrs)

  def create_endpoint(%App{id: app_id}, attrs, actor \\ nil) do
    %Endpoint{app_id: app_id}
    |> Endpoint.changeset(attrs)
    |> audited_write(:insert, actor, "webhook.created")
  end

  def update_endpoint(%Endpoint{} = endpoint, attrs, actor \\ nil) do
    endpoint
    |> Endpoint.changeset(attrs)
    |> audited_write(:update, actor, "webhook.updated")
  end

  def delete_endpoint(%Endpoint{} = endpoint, actor \\ nil) do
    endpoint
    |> Ecto.Changeset.change()
    |> audited_write(:delete, actor, "webhook.deleted")
  end

  defp audited_write(changeset, operation, actor, action) do
    Ecto.Multi.new()
    |> then(&apply(Ecto.Multi, operation, [&1, :endpoint, changeset]))
    |> Ecto.Multi.run(:audit, fn _repo, %{endpoint: endpoint} ->
      Audit.log(actor, action, endpoint.app_id, %{
        endpoint_id: endpoint.id,
        url: endpoint.url,
        events: endpoint.events,
        active: endpoint.active
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{endpoint: endpoint}} ->
        Apps.refresh(endpoint.app_id)
        {:ok, endpoint}

      {:error, :endpoint, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc "Most recent deliveries for an app, newest first."
  def list_deliveries(app_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(d in Delivery,
      where: d.app_id == ^app_id,
      order_by: [desc: d.inserted_at, desc: d.id],
      limit: ^limit,
      preload: [:endpoint]
    )
    |> maybe_endpoint(Keyword.get(opts, :endpoint_id))
    |> Repo.all()
  end

  defp maybe_endpoint(query, nil), do: query
  defp maybe_endpoint(query, id), do: where(query, [d], d.endpoint_id == ^id)

  @doc "Pending and in-flight deliveries across all apps."
  def queue_depth do
    Repo.aggregate(from(d in Delivery, where: d.status in ["pending", "in_flight"]), :count)
  end
end
