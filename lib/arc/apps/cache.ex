defmodule Arc.Apps.Cache do
  @moduledoc """
  App configs held in `:persistent_term`, keyed by id and by public key.

  Lookups are a constant-time read with no copying, which is what lets a WebSocket
  handshake or a signed API call resolve its app without touching Postgres. Writes go
  through `Arc.Apps`, which updates the local node synchronously and then broadcasts
  the new config to every other node in the cluster.

  The cache is warmed from Postgres when this process starts. Until the warm succeeds
  `ready?/0` is false and the health endpoint reports not ready; if Postgres is not
  reachable on boot the warm is retried with backoff instead of crashing the node.
  """
  use GenServer
  require Logger

  alias Arc.Apps.Config

  @topic "arc:apps"
  @ready {__MODULE__, :ready}
  @index {__MODULE__, :index}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Looks up an app by its numeric id."
  @spec get(integer() | String.t()) :: Config.t() | nil
  def get(id) when is_integer(id), do: :persistent_term.get({__MODULE__, :id, id}, nil)

  def get(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> get(int)
      _ -> nil
    end
  end

  @doc "Looks up an app by its public key."
  @spec get_by_key(String.t()) :: Config.t() | nil
  def get_by_key(key) when is_binary(key), do: :persistent_term.get({__MODULE__, :key, key}, nil)

  @doc "Ids of every cached app."
  def ids, do: :persistent_term.get(@index, MapSet.new()) |> MapSet.to_list()

  @doc "True once the cache has been warmed from the database."
  def ready?, do: :persistent_term.get(@ready, false)

  @doc """
  Stores a config on this node and broadcasts it to the rest of the cluster.
  Older versions never replace newer ones, so out-of-order delivery is harmless.
  """
  def publish(%Config{} = config) do
    put(config)
    broadcast({:app_updated, config})
  end

  @doc "Removes an app on this node and on the rest of the cluster."
  def publish_delete(id) when is_integer(id) do
    delete(id)
    broadcast({:app_deleted, id})
  end

  @doc false
  def put(%Config{id: id, key: key} = config) do
    case get(id) do
      %Config{version: current} when current > config.version ->
        :stale

      previous ->
        if previous && previous.key != key do
          :persistent_term.erase({__MODULE__, :key, previous.key})
        end

        :persistent_term.put({__MODULE__, :id, id}, config)
        :persistent_term.put({__MODULE__, :key, key}, config)
        :persistent_term.put(@index, MapSet.put(:persistent_term.get(@index, MapSet.new()), id))
        :ok
    end
  end

  @doc false
  def delete(id) do
    case get(id) do
      nil ->
        :ok

      %Config{key: key} ->
        :persistent_term.erase({__MODULE__, :id, id})
        :persistent_term.erase({__MODULE__, :key, key})

        :persistent_term.put(
          @index,
          MapSet.delete(:persistent_term.get(@index, MapSet.new()), id)
        )

        :ok
    end
  end

  @doc "Reloads every app from the database. Used on boot and after a netsplit heals."
  def warm do
    configs = Arc.Apps.list_apps() |> Enum.map(&Config.from_app/1)
    live_ids = MapSet.new(configs, & &1.id)

    for id <- ids(), not MapSet.member?(live_ids, id), do: delete(id)
    Enum.each(configs, &put/1)
    :persistent_term.put(@ready, true)
    {:ok, length(configs)}
  end

  defp broadcast(message) do
    case Process.whereis(__MODULE__) do
      nil -> Phoenix.PubSub.broadcast(Arc.PubSub, @topic, message)
      pid -> Phoenix.PubSub.broadcast_from(Arc.PubSub, pid, @topic, message)
    end
  end

  ## GenServer

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Arc.PubSub, @topic)
    :ok = :net_kernel.monitor_nodes(true)

    # Warm synchronously so the endpoint, which starts after this process, never
    # accepts a connection against an empty cache. If Postgres is unreachable the node
    # still boots, reports not-ready, and keeps retrying.
    {:ok, try_warm(%{attempt: 0})}
  end

  @impl true
  def handle_info(:warm, state), do: {:noreply, try_warm(state)}

  def handle_info({:app_updated, config}, state) do
    put(config)
    {:noreply, state}
  end

  def handle_info({:app_deleted, id}, state) do
    delete(id)
    {:noreply, state}
  end

  # A node rejoining after a partition may have missed broadcasts; resync from the
  # database, which is the source of truth.
  def handle_info({:nodeup, _node}, state) do
    send(self(), :warm)
    {:noreply, state}
  end

  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  defp try_warm(state) do
    {:ok, count} = warm()
    Logger.info("app config cache warmed with #{count} apps")
    %{state | attempt: 0}
  rescue
    error ->
      delay = min(30_000, 500 * Integer.pow(2, state.attempt))

      Logger.warning(
        "app config cache warm failed, retrying in #{delay}ms: #{Exception.message(error)}"
      )

      Process.send_after(self(), :warm, delay)
      %{state | attempt: state.attempt + 1}
  end
end
