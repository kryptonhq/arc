defmodule Arc.Application do
  @moduledoc false

  use Application

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

  @impl true
  def prep_stop(state) do
    # Close client connections with a reconnect-after-backoff code so clients move to
    # another node instead of treating the shutdown as a failure.
    try do
      Arc.Realtime.drain_node()
    rescue
      # The tree may already be gone if the application is stopping after a failure.
      ArgumentError -> :ok
    end

    state
  end

  @impl true
  def config_change(changed, _new, removed) do
    ArcWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
