defmodule Arc.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        ArcWeb.Telemetry,
        Arc.Repo,
        Arc.Vault,
        {Cluster.Supervisor,
         [Application.get_env(:libcluster, :topologies, []), [name: Arc.ClusterSupervisor]]},
        {Phoenix.PubSub, name: Arc.PubSub},
        # Warmed before the endpoint starts so no handshake ever needs Postgres.
        Arc.Apps.Cache,
        Arc.Health,
        Arc.RateLimiter,
        Arc.Realtime.Supervisor,
        Arc.Webhooks.Supervisor,
        Arc.Metrics.Supervisor
      ] ++
        Arc.Admin.OIDC.child_specs() ++
        [
          ArcWeb.Endpoint
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Arc.Supervisor)
  end

  @doc """
  Graceful shutdown, in the order a load balancer needs:

  1. Readiness reports 503 so no new traffic is routed here.
  2. Wait `drain_seconds` for the balancer's health check to notice.
  3. Close every client connection with 4101 (reconnect after backoff) so clients
     move to another node, and flush webhook batches that have not been persisted.

  Only then does the supervision tree stop. The platform's stop grace period must be
  longer than the drain window or the VM is killed mid-drain.
  """
  @impl true
  def prep_stop(state) do
    drain(Application.get_env(:arc, :drain_seconds, 5))
    state
  end

  @doc false
  def drain(seconds) do
    Arc.Health.start_drain()

    if seconds > 0 do
      Logger.info("draining: waiting #{seconds}s for the load balancer before closing clients")
      Process.sleep(seconds * 1000)
    end

    safely(fn -> Arc.Realtime.drain_node() end)
    safely(fn -> Arc.Webhooks.Batcher.flush_all() end)
    :ok
  end

  # The tree may already be gone if the application is stopping after a failure.
  defp safely(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def config_change(changed, _new, removed) do
    ArcWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
