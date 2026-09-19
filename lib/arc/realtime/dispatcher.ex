defmodule Arc.Realtime.Dispatcher do
  @moduledoc """
  Fan-out of encoded frames to channel subscribers across the cluster.

  A broadcast encodes its frame once. The binary is then handed to every local
  subscriber by walking the channel's registry entries; large binaries are reference
  counted, so this costs one pointer per subscriber rather than one copy.

  Other nodes are reached by sending the frame to the dispatcher shard with the same
  index on each node. The shard is chosen by `:erlang.phash2(channel, shard_count)`,
  so traffic for a hot channel queues behind its own shard only, and frames for any
  one channel keep their order between any two nodes.
  """
  use GenServer

  alias Arc.Realtime.{ChannelCache, Registries}

  @doc false
  def child_spec(_opts) do
    children =
      for index <- 0..(shard_count() - 1) do
        %{id: {__MODULE__, index}, start: {__MODULE__, :start_link, [index]}}
      end

    %{
      id: __MODULE__,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
    }
  end

  def start_link(index), do: GenServer.start_link(__MODULE__, index, name: shard_name(index))

  @doc """
  Delivers `frame` to every subscriber of `channel`, on every node, except the
  connection whose socket id is `except`.

  With `cache: true` the frame is also retained as the channel's last event on every
  node, for replay to later subscribers.
  """
  @spec broadcast(integer(), String.t(), binary(), String.t() | nil, keyword()) :: :ok
  def broadcast(app_id, channel, frame, except \\ nil, opts \\ []) do
    start = System.monotonic_time()
    cache? = Keyword.get(opts, :cache, false)
    deliver(app_id, channel, frame, except, cache?)

    case Node.list() do
      [] ->
        :ok

      nodes ->
        shard = shard_name(:erlang.phash2(channel, shard_count()))
        message = {:broadcast, app_id, channel, frame, except, cache?}
        Enum.each(nodes, &send({shard, &1}, message))
    end

    :telemetry.execute(
      [:arc, :broadcast, :stop],
      %{duration: System.monotonic_time() - start},
      %{app_id: app_id}
    )

    :ok
  end

  defp deliver(app_id, channel, frame, except, cache?) do
    if cache?, do: ChannelCache.put(app_id, channel, frame)
    dispatch_local(app_id, channel, frame, except)
  end

  @doc "Delivers `frame` to subscribers on this node only."
  def dispatch_local(app_id, channel, frame, except \\ nil) do
    Registry.dispatch(Registries.Channels, {app_id, channel}, fn entries ->
      for {pid, socket_id} <- entries, socket_id != except do
        send(pid, {:arc_frame, frame})
      end
    end)
  end

  @doc """
  Sends `message` to every connection on every node that matches `key` in the given
  registry. Used for app-wide and user-wide actions such as terminating connections.
  """
  def send_all(registry, key, message) do
    send_all_local(registry, key, message)

    for node <- Node.list() do
      send(
        {shard_name(:erlang.phash2(key, shard_count())), node},
        {:send_all, registry, key, message}
      )
    end

    :ok
  end

  def send_all_local(registry, key, message) do
    Registry.dispatch(registry, key, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end

  @impl true
  def init(_index), do: {:ok, nil}

  @impl true
  def handle_info({:broadcast, app_id, channel, frame, except, cache?}, state) do
    deliver(app_id, channel, frame, except, cache?)
    {:noreply, state}
  end

  def handle_info({:send_all, registry, key, message}, state) do
    send_all_local(registry, key, message)
    {:noreply, state}
  end

  # Fixed rather than derived from the scheduler count: a remote node must have a shard
  # with the same index, whatever its core count.
  @shard_count 32
  defp shard_count, do: @shard_count
  defp shard_name(index), do: :"#{__MODULE__}.#{index}"
end
