defmodule ArcWeb.Plugs.Session do
  @moduledoc """
  `Plug.Session` with options decided at boot rather than compile time, so the cookie's
  `Secure` flag follows `PHX_PUBLIC_SCHEME`: set for `https` (the default), off only
  when an install is explicitly plain `http`.
  """
  @behaviour Plug

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts), do: Plug.Session.call(conn, Plug.Session.init(options()))

  @doc "The session options in force, also used for the LiveView socket."
  @spec options() :: keyword()
  def options do
    [
      store: :cookie,
      key: "_arc_key",
      signing_salt: "PT+l6AYi",
      same_site: "Lax",
      # Dashboard sessions last 12 hours; ArcWeb.AdminAuth enforces the same limit
      # server-side from the sign-in time.
      max_age: 12 * 60 * 60,
      http_only: true,
      secure: Application.get_env(:arc, :secure_cookies, true)
    ]
  end
end
