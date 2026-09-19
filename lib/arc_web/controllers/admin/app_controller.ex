defmodule ArcWeb.Admin.AppController do
  @moduledoc """
  Forms for creating and changing apps. Secrets are rendered directly in the response
  to the action that produced them and never stored in the session or flash, so they
  are shown exactly once.
  """
  use ArcWeb, :controller

  alias Arc.Apps

  plug :put_view, ArcWeb.Admin.AppHTML

  def new(conn, _params) do
    render(conn, :new, changeset: Apps.change_app(), page_title: "New app")
  end

  def create(conn, %{"app" => params}) do
    case Apps.create_app(params, conn.assigns.current_admin) do
      {:ok, app, secret} ->
        render(conn, :credentials,
          app: app,
          secret: secret,
          heading: "#{app.name} is ready",
          page_title: app.name
        )

      {:error, changeset} ->
        conn |> put_status(422) |> render(:new, changeset: changeset, page_title: "New app")
    end
  end

  def edit(conn, %{"id" => id}) do
    app = Apps.get_app!(id)

    render(conn, :edit,
      app: app,
      changeset: Apps.change_app(app),
      page_title: "Settings · #{app.name}"
    )
  end

  def update(conn, %{"id" => id, "app" => params}) do
    app = Apps.get_app!(id)

    case Apps.update_app(app, params, conn.assigns.current_admin) do
      {:ok, app} ->
        conn |> put_flash(:info, "Settings saved.") |> redirect(to: ~p"/admin/apps/#{app.id}")

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> render(:edit, app: app, changeset: changeset, page_title: "Settings")
    end
  end

  def rotate(conn, %{"id" => id}) do
    {:ok, app, secret} = Apps.rotate_secret(Apps.get_app!(id), conn.assigns.current_admin)

    render(conn, :credentials,
      app: app,
      secret: secret,
      heading: "Secret rotated",
      page_title: app.name
    )
  end

  def encryption_key(conn, %{"id" => id, "action" => "generate"}) do
    key = Apps.generate_encryption_master_key()

    {:ok, app} =
      Apps.put_encryption_master_key(Apps.get_app!(id), key, conn.assigns.current_admin)

    render(conn, :master_key, app: app, master_key: key, page_title: app.name)
  end

  def encryption_key(conn, %{"id" => id, "action" => "remove"}) do
    {:ok, app} =
      Apps.put_encryption_master_key(Apps.get_app!(id), nil, conn.assigns.current_admin)

    conn
    |> put_flash(
      :info,
      "Encryption master key removed. Publishing to encrypted channels is disabled."
    )
    |> redirect(to: ~p"/admin/apps/#{app.id}")
  end

  def delete(conn, %{"id" => id}) do
    {:ok, app} = Apps.delete_app(Apps.get_app!(id), conn.assigns.current_admin)
    conn |> put_flash(:info, "#{app.name} deleted.") |> redirect(to: ~p"/admin/apps")
  end
end
