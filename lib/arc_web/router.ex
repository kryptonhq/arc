defmodule ArcWeb.Router do
  use ArcWeb, :router

  # The dashboard loads its own bundles and the IBM Plex fonts from Google, and talks to
  # LiveView over a same-origin WebSocket. Nothing else, and never inline scripts.
  @csp Enum.join(
         [
           "default-src 'self'",
           "script-src 'self'",
           "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
           "font-src 'self' data: https://fonts.gstatic.com",
           "img-src 'self' data:",
           "connect-src 'self' ws: wss:",
           "frame-ancestors 'none'",
           "base-uri 'self'",
           "form-action 'self'",
           "object-src 'none'"
         ],
         "; "
       )

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ArcWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  end

  pipeline :require_admin do
    plug :require_admin_plug
  end

  pipeline :signed_api do
    plug ArcWeb.Plugs.ApiAuth
  end

  # The HTTP API used by application backends and server SDKs.
  scope "/apps/:app_id", ArcWeb.Api do
    pipe_through :signed_api

    post "/events", ApiController, :events
    post "/batch_events", ApiController, :batch_events
    get "/channels", ApiController, :channels
    get "/channels/:channel_name", ApiController, :channel
    get "/channels/:channel_name/users", ApiController, :users
    post "/users/:user_id/terminate_connections", ApiController, :terminate_connections
  end

  # Some server SDKs address user operations without an app id; the app is found by
  # the request's auth_key.
  scope "/users", ArcWeb.Api do
    pipe_through :signed_api

    post "/:user_id/terminate_connections", ApiController, :terminate_connections
  end

  scope "/", ArcWeb do
    get "/health/live", HealthController, :live
    get "/health/ready", HealthController, :ready
    get "/metrics", MetricsController, :index
  end

  scope "/auth", ArcWeb do
    pipe_through :browser

    get "/login", AuthController, :login
    get "/callback", AuthController, :callback
    get "/logout", AuthController, :logout
  end

  # Every route under /admin goes through :require_admin, and every LiveView through
  # the matching on_mount hook, so no page can be added without the check.
  scope "/admin", ArcWeb.Admin do
    pipe_through [:browser, :require_admin]

    # Before the live routes so "new" is not taken for an app id.
    get "/apps/new", AppController, :new

    live_session :admin, on_mount: {ArcWeb.AdminAuth, :require_admin} do
      live "/", OverviewLive
      live "/apps", AppsLive
      live "/apps/:id", AppLive
    end

    post "/apps", AppController, :create
    get "/apps/:id/edit", AppController, :edit
    put "/apps/:id", AppController, :update
    delete "/apps/:id", AppController, :delete
    post "/apps/:id/rotate", AppController, :rotate
    post "/apps/:id/encryption_key", AppController, :encryption_key

    get "/apps/:app_id/webhooks", WebhookController, :index
    post "/apps/:app_id/webhooks", WebhookController, :create
    get "/apps/:app_id/webhooks/:id/edit", WebhookController, :edit
    put "/apps/:app_id/webhooks/:id", WebhookController, :update
    delete "/apps/:app_id/webhooks/:id", WebhookController, :delete
    post "/apps/:app_id/webhooks/:id/retry", WebhookController, :retry

    get "/audit", AuditController, :index
  end

  scope "/", ArcWeb do
    pipe_through :browser

    get "/", RedirectController, :admin
  end

  defp require_admin_plug(conn, opts), do: ArcWeb.AdminAuth.require_admin(conn, opts)
end
