defmodule ArcWeb.HealthController do
  @moduledoc """
  Liveness and readiness.

  * `/health/live` — 200 while the VM is running.
  * `/health/ready` — 200 while the node should receive traffic: migrations applied,
    app config cache warm, Postgres reachable on the last check, and not draining.
    503 otherwise, with a one-word reason in the body. See `Arc.Health`.
  """
  use ArcWeb, :controller

  def live(conn, _params), do: text(conn, "ok")

  def ready(conn, _params) do
    cond do
      Arc.Health.draining?() -> conn |> put_status(503) |> text("draining")
      not Arc.Health.db_ok?() -> conn |> put_status(503) |> text("database unreachable")
      Arc.Health.ready?() -> text(conn, "ready")
      true -> conn |> put_status(503) |> text("not ready")
    end
  end
end
