defmodule Arc.Health do
  @moduledoc """
  Readiness and drain state for one node.

  `/health/ready` is what a load balancer asks before routing to this node, so it has
  to reflect reality throughout the process's life, not only at boot:

  * **Boot:** ready once the app config cache is warm and every migration is up. The
    migration check hits Postgres and cannot flip back, so a positive answer is kept.
  * **Postgres:** a `SELECT 1` runs every `db_check_interval` ms and the last answer is
    cached; probes never touch the database themselves. Readiness goes false while
    Postgres is unreachable. Existing connections, subscriptions, and publishes keep
    working (the data plane never needs the database), so this only steers new
    traffic to nodes that can also serve the dashboard, webhooks, and sign-in.
  * **Drain:** `start_drain/0` flips readiness to false immediately. The application's
    `prep_stop/1` calls it, waits for the load balancer to notice, and only then
    closes client connections.

  Liveness (`/health/live`) stays unconditional: a draining or database-less node is
  still alive.
  """
  use GenServer

  require Logger

  @draining {__MODULE__, :draining}
  @db_ok {__MODULE__, :db_ok}
  @migrated {__MODULE__, :migrated}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "True when this node should receive new traffic."
  @spec ready?() :: boolean()
  def ready? do
    not draining?() and db_ok?() and Arc.Apps.Cache.ready?() and migrations_applied?()
  end

  @doc "True once `start_drain/0` was called on this node."
  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get(@draining, false)

  @doc "True if the last database check succeeded (or none has run yet)."
  @spec db_ok?() :: boolean()
  def db_ok?, do: :persistent_term.get(@db_ok, true)

  @doc """
  Marks the node as draining so readiness reports 503 at once. Idempotent. Returns
  `true` if this call started the drain, `false` if it was already draining.
  """
  @spec start_drain() :: boolean()
  def start_drain do
    if draining?() do
      false
    else
      :persistent_term.put(@draining, true)
      Logger.info("draining: readiness now reports not ready")
      true
    end
  end

  @doc "Clears the drain flag. Used by tests; a real drain ends with the process."
  @spec stop_drain() :: :ok
  def stop_drain, do: :persistent_term.put(@draining, false)

  @doc "Runs the database check now instead of waiting for the next interval."
  @spec check_db_now() :: boolean()
  def check_db_now, do: GenServer.call(__MODULE__, :check_db)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :db_check_interval, config(:db_check_interval))
    :persistent_term.put(@draining, false)
    :persistent_term.put(@db_ok, true)
    if interval, do: Process.send_after(self(), :check_db, interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_call(:check_db, _from, state), do: {:reply, check_db(), state}

  @impl true
  def handle_info(:check_db, state) do
    check_db()
    Process.send_after(self(), :check_db, state.interval)
    {:noreply, state}
  end

  defp check_db do
    ok = db_reachable?()
    was_ok = db_ok?()
    :persistent_term.put(@db_ok, ok)

    cond do
      was_ok and not ok -> Logger.warning("readiness: Postgres is unreachable")
      ok and not was_ok -> Logger.info("readiness: Postgres is back")
      true -> :ok
    end

    ok
  end

  # An unreachable server is an error tuple; a Repo that is down entirely (no pool
  # process) raises instead. Both mean "not reachable".
  defp db_reachable? do
    match?({:ok, _}, Ecto.Adapters.SQL.query(Arc.Repo, "SELECT 1", [], timeout: 2_000))
  rescue
    _ -> false
  end

  @doc false
  def migrations_applied? do
    :persistent_term.get(@migrated, false) or check_migrations()
  end

  defp check_migrations do
    applied =
      Arc.Repo
      |> Ecto.Migrator.migrations()
      |> Enum.all?(fn {status, _version, _name} -> status == :up end)

    if applied, do: :persistent_term.put(@migrated, true)
    applied
  rescue
    _ -> false
  end

  defp config(key), do: Application.fetch_env!(:arc, __MODULE__) |> Keyword.fetch!(key)
end
