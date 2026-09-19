defmodule ArcWeb.AuthController do
  @moduledoc "OIDC sign-in and sign-out for the dashboard."
  use ArcWeb, :controller

  require Logger

  alias Arc.Admin
  alias Arc.Admin.OIDC
  alias ArcWeb.AdminAuth

  def login(conn, _params) do
    flow = OIDC.new_flow()

    case OIDC.authorize_url(callback_url(), flow) do
      {:ok, url} ->
        conn
        |> put_session(:oidc_flow, flow)
        |> redirect(external: url)

      {:error, reason} ->
        Logger.warning("OIDC sign-in could not start: #{inspect(reason)}")

        conn
        |> put_status(503)
        |> put_view(ArcWeb.AuthHTML)
        |> render(:error,
          message: "The identity provider is not reachable. Try again in a moment."
        )
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    flow = get_session(conn, :oidc_flow)
    conn = delete_session(conn, :oidc_flow)

    with %{state: expected} <- flow,
         true <- Plug.Crypto.secure_compare(expected, state),
         {:ok, claims} <- OIDC.exchange(code, callback_url(), flow),
         {:ok, admin} <- Admin.sign_in(claims) do
      return_to = get_session(conn, :return_to) || ~p"/admin"

      conn
      |> AdminAuth.put_admin(admin)
      |> redirect(to: return_to)
    else
      {:error, :not_allowed} ->
        forbidden(conn, "Your account is not on this Arc installation's administrator list.")

      {:error, :email_unverified} ->
        forbidden(conn, "Your email address has not been verified by the identity provider.")

      {:error, :email_missing} ->
        forbidden(conn, "The identity provider did not share an email address.")

      other ->
        Logger.info("OIDC callback rejected: #{inspect(other)}")
        bad_request(conn)
    end
  end

  def callback(conn, _params), do: bad_request(conn)

  def logout(conn, _params) do
    conn = clear_session(conn) |> configure_session(drop: true)

    case OIDC.logout_url(url(~p"/")) do
      {:ok, url} -> redirect(conn, external: url)
      {:error, _} -> redirect(conn, to: ~p"/")
    end
  end

  defp callback_url, do: url(~p"/auth/callback")

  defp forbidden(conn, message) do
    conn
    |> clear_session()
    |> put_status(403)
    |> put_view(ArcWeb.AuthHTML)
    |> render(:forbidden, message: message)
  end

  defp bad_request(conn) do
    conn
    |> put_status(400)
    |> put_view(ArcWeb.AuthHTML)
    |> render(:error, message: "The sign-in attempt was invalid or expired. Start again.")
  end
end
