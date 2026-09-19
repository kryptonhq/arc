defmodule ArcWeb.HealthController do
  @moduledoc """
  Liveness and readiness.

  * `/health/live` — 200 while the VM is running.
  * `/health/ready` — 200 once migrations are applied and the app config cache is
    warm; 503 before that, so load balancers hold traffic until the node can serve it.
  """
  use ArcWeb, :controller

  def live(conn, _params), do: text(conn, "ok")

  def ready(conn, _params) do
    if Arc.Health.ready?() do
      text(conn, "ready")
    else
      conn |> put_status(503) |> text("not ready")
    end
  end
end
