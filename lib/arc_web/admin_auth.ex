defmodule ArcWeb.AdminAuth do
  @moduledoc """
  Guards everything under `/admin`.

  The session holds only the admin's OIDC subject, email, and sign-in time; no tokens
  are kept, since Arc calls nothing on the admin's behalf. Sessions last 12 hours.
  Every request re-checks the email against the allowlist, so a removed admin loses
  access immediately.

  The check lives in the router pipeline (`:require_admin`) and in the LiveView
  `on_mount` hook, so a new page cannot be added without it.
  """
  use ArcWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Arc.Admin

  @max_age 12 * 60 * 60

  def max_age, do: @max_age

  @doc "Stores a signed-in admin in the session."
  def put_admin(conn, admin) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:admin_email, admin.email)
    |> put_session(:admin_subject, admin.subject)
    |> put_session(:signed_in_at, System.system_time(:second))
  end

  @doc "Plug: requires a signed-in admin, otherwise starts the sign-in flow."
  def require_admin(conn, _opts) do
    case current_admin(get_session(conn)) do
      nil ->
        conn
        |> clear_session()
        |> put_session(
          :return_to,
          if(conn.method == "GET", do: current_path(conn), else: ~p"/admin")
        )
        |> redirect(to: ~p"/auth/login")
        |> halt()

      admin ->
        assign(conn, :current_admin, admin)
    end
  end

  @doc "LiveView mount hook with the same rules as `require_admin/2`."
  def on_mount(:require_admin, _params, session, socket) do
    case current_admin(session) do
      nil -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/auth/login")}
      admin -> {:cont, Phoenix.Component.assign(socket, :current_admin, admin)}
    end
  end

  defp current_admin(%{"admin_email" => email, "signed_in_at" => signed_in_at})
       when is_integer(signed_in_at) do
    if System.system_time(:second) - signed_in_at < @max_age, do: Admin.get_by_email(email)
  end

  defp current_admin(_session), do: nil
end
