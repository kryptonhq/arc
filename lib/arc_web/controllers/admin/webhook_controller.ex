defmodule ArcWeb.Admin.WebhookController do
  use ArcWeb, :controller

  alias Arc.{Apps, Webhooks}

  plug :put_view, ArcWeb.Admin.WebhookHTML

  def index(conn, %{"app_id" => app_id}) do
    app = Apps.get_app!(app_id)
    render_index(conn, app, Webhooks.change_endpoint(%Webhooks.Endpoint{}, %{}))
  end

  def create(conn, %{"app_id" => app_id, "endpoint" => params}) do
    app = Apps.get_app!(app_id)

    case Webhooks.create_endpoint(app, params, conn.assigns.current_admin) do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Webhook endpoint added.")
        |> redirect(to: ~p"/admin/apps/#{app.id}/webhooks")

      {:error, changeset} ->
        conn |> put_status(422) |> render_index(app, changeset)
    end
  end

  def edit(conn, %{"app_id" => app_id, "id" => id}) do
    app = Apps.get_app!(app_id)
    endpoint = Webhooks.get_endpoint!(app.id, id)

    render(conn, :edit,
      app: app,
      endpoint: endpoint,
      changeset: Webhooks.change_endpoint(endpoint),
      page_title: "Webhook"
    )
  end

  def update(conn, %{"app_id" => app_id, "id" => id, "endpoint" => params}) do
    app = Apps.get_app!(app_id)
    endpoint = Webhooks.get_endpoint!(app.id, id)
    params = Map.put_new(params, "events", [])

    case Webhooks.update_endpoint(endpoint, params, conn.assigns.current_admin) do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Webhook endpoint updated.")
        |> redirect(to: ~p"/admin/apps/#{app.id}/webhooks")

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> render(:edit,
          app: app,
          endpoint: endpoint,
          changeset: changeset,
          page_title: "Webhook"
        )
    end
  end

  def delete(conn, %{"app_id" => app_id, "id" => id}) do
    app = Apps.get_app!(app_id)

    {:ok, _} =
      Webhooks.delete_endpoint(Webhooks.get_endpoint!(app.id, id), conn.assigns.current_admin)

    conn
    |> put_flash(:info, "Webhook endpoint removed.")
    |> redirect(to: ~p"/admin/apps/#{app.id}/webhooks")
  end

  defp render_index(conn, app, changeset) do
    render(conn, :index,
      app: app,
      endpoints: Webhooks.list_endpoints(app.id),
      deliveries: Webhooks.list_deliveries(app.id, limit: 100),
      changeset: changeset,
      page_title: "Webhooks · #{app.name}"
    )
  end
end
