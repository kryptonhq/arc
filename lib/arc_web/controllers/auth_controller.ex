defmodule ArcWeb.AuthController do
  @moduledoc """
  Sign-in and sign-out for the dashboard.

  Two ways in, both ending in the same `ArcWeb.AdminAuth` session:

  * **OIDC**, the default: `/auth/login` starts the authorization-code flow and
    `/auth/callback` completes it.
  * **Password**, when `ARC_ADMIN_PASSWORD` is set: `/auth/login` renders a page with
    a password form (and the provider link, if one is configured) and
    `/auth/password` checks it. Attempts are limited per client address and every
    failure is logged with that address, never with what was submitted.
  """
  use ArcWeb, :controller

  require Logger

  alias Arc.Admin
  alias Arc.Admin.OIDC
  alias ArcWeb.AdminAuth

  # Password attempts per client address per minute.
  @password_attempts_per_minute 5

  def login(conn, _params) do
    if Admin.password_enabled?(),
      do: render_login(conn, nil),
      else: start_oidc(conn)
  end

  @doc false
  def start_oidc(conn) do
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

  # The provider link on the password page starts the flow explicitly.
  def oidc(conn, _params) do
    if OIDC.configured?(), do: start_oidc(conn), else: redirect(conn, to: ~p"/auth/login")
  end

  def password(conn, params) do
    ip = conn.remote_ip

    with :ok <- check_password_rate(ip),
         {:ok, admin} <- Admin.password_sign_in(params["password"]) do
      return_to = get_session(conn, :return_to) || ~p"/admin"

      conn
      |> AdminAuth.put_admin(admin)
      |> redirect(to: return_to)
    else
      {:error, :rate_limited} ->
        Logger.warning("password sign-in rate limited client_ip=#{:inet.ntoa(ip)}")

        conn
        |> put_status(429)
        |> put_resp_content_type("text/plain")
        |> send_resp(429, "Too many sign-in attempts from this address. Retry in a minute.\n")

      {:error, :invalid} ->
        Logger.warning("password sign-in failed client_ip=#{:inet.ntoa(ip)}")
        conn |> put_status(401) |> render_login("That password is not right.")
    end
  end

  defp check_password_rate(ip) do
    case Arc.RateLimiter.take(
           {:password, ip},
           @password_attempts_per_minute / 60,
           @password_attempts_per_minute
         ) do
      :ok -> :ok
      {:error, _} -> {:error, :rate_limited}
    end
  end

  defp render_login(conn, error) do
    conn
    |> put_view(ArcWeb.AuthHTML)
    |> render(:login, error: error, oidc?: OIDC.configured?(), page_title: "Sign in")
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

    # A password session has no provider session to end; an OIDC one is ended at the
    # provider so the next sign-in asks for credentials again.
    with true <- OIDC.configured?(),
         {:ok, url} <- OIDC.logout_url(url(~p"/")) do
      redirect(conn, external: url)
    else
      _ -> redirect(conn, to: ~p"/")
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
