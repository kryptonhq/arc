defmodule Arc.Realtime.Occupancy do
  @moduledoc """
  Node-local counts of connections per app and subscriptions per channel.

  Counters live in public ETS tables so reads (connection limits, channel queries,
  the metrics aggregator) never block. Writes go through a set of shard processes,
  chosen by the socket pid, which also monitor each socket: when a socket process
  exits for any reason, including a crash, its shard releases every count it held.
  This is what keeps counts and occupancy webhooks from drifting.

  Transitions of a channel's node-local count between 0 and 1 are reported to
  `Arc.Webhooks.Events`, which applies the cluster-wide check and the debounce.
  """
  use GenServer

  @channels :arc_channel_subscriptions
  @connections :arc_app_connections

  @doc false
  def child_spec(_opts) do
    shards = shard_count()

    children =
      for index <- 0..(shards - 1) do
        %{id: {__MODULE__, index}, start: {__MODULE__, :start_link, [index]}}
      end

    %{
      id: __MODULE__,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
    }
  end

  @doc "Creates the counter tables. Called once by the realtime supervisor."
  def create_tables do
    opts = [:named_table, :public, :set, read_concurrency: true, write_concurrency: true]
    :ets.new(@channels, opts)
    :ets.new(@connections, opts)
    :ok
  end

  def start_link(index), do: GenServer.start_link(__MODULE__, index, name: shard_name(index))

  ## API used by sockets. All calls are casts from the socket to its own shard, so the
  ## order of a socket's own operations is preserved.

  def connect(app_id), do: GenServer.cast(shard_for(self()), {:connect, self(), app_id})

  def subscribe(app_id, channel, type),
    do: GenServer.cast(shard_for(self()), {:subscribe, self(), app_id, channel, type})

  def unsubscribe(app_id, channel),
    do: GenServer.cast(shard_for(self()), {:unsubscribe, self(), app_id, channel})

  ## Reads.

  @doc "Connections on this node for an app."
  def connection_count(app_id), do: lookup(@connections, app_id)

  @doc "Connections on this node across all apps."
  def total_connections, do: lookup(@connections, :total)

  @doc "Subscriptions on this node for a channel."
  def subscription_count(app_id, channel), do: lookup(@channels, {app_id, channel})

  @doc "Occupied channels on this node for an app, as `[{name, subscription_count}]`."
  def channels(app_id) do
    :ets.select(@channels, [{{{app_id, :"$1"}, :"$2"}, [{:>, :"$2", 0}], [{{:"$1", :"$2"}}]}])
  end

  @doc "Connection counts per app on this node, as a map."
  def connections_by_app do
    :ets.select(@connections, [{{:"$1", :"$2"}, [{:is_integer, :"$1"}], [{{:"$1", :"$2"}}]}])
    |> Map.new()
  end

  @doc "Occupied channel and subscription totals per app on this node."
  def channel_stats do
    :ets.foldl(
      fn
        {{app_id, _name}, count}, acc when count > 0 ->
          Map.update(acc, app_id, {1, count}, fn {c, s} -> {c + 1, s + count} end)

        _, acc ->
          acc
      end,
      %{},
      @channels
    )
  end

  @doc "Occupied channels per app and channel type on this node, for metrics."
  def channels_by_type do
    :ets.foldl(
      fn
        {{app_id, name}, count}, acc when count > 0 ->
          type =
            case Arc.Channels.Channel.parse(name) do
              {:ok, channel} -> Arc.Channels.Channel.metric_type(channel)
              _ -> "unknown"
            end

          Map.update(acc, {app_id, type}, 1, &(&1 + 1))

        _, acc ->
          acc
      end,
      %{},
      @channels
    )
  end

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{_, count}] -> count
      [] -> 0
    end
  end

  ## Shard.

  @impl true
  def init(_index) do
    # pid => %{ref, app_id, channels: %{name => type}}
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:connect, pid, app_id}, sockets) do
    ref = Process.monitor(pid)
    incr(@connections, app_id, 1)
    incr(@connections, :total, 1)
    :telemetry.execute([:arc, :connection, :open], %{count: 1}, %{app_id: app_id})
    {:noreply, Map.put(sockets, pid, %{ref: ref, app_id: app_id, channels: %{}, at: now()})}
  end

  def handle_cast({:subscribe, pid, app_id, channel, type}, sockets) do
    case sockets do
      %{^pid => %{channels: %{^channel => _}}} ->
        {:noreply, sockets}

      %{^pid => socket} ->
        join_channel(app_id, channel, type)
        {:noreply, put_in(sockets, [pid, :channels], Map.put(socket.channels, channel, type))}

      _ ->
        {:noreply, sockets}
    end
  end

  def handle_cast({:unsubscribe, pid, app_id, channel}, sockets) do
    case sockets do
      %{^pid => %{channels: %{^channel => type} = channels}} ->
        leave_channel(app_id, channel, type)
        {:noreply, put_in(sockets, [pid, :channels], Map.delete(channels, channel))}

      _ ->
        {:noreply, sockets}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, sockets) do
    case Map.pop(sockets, pid) do
      {nil, sockets} ->
        {:noreply, sockets}

      {socket, sockets} ->
        Enum.each(socket.channels, fn {channel, type} ->
          leave_channel(socket.app_id, channel, type)
        end)

        decr(@connections, socket.app_id)
        decr(@connections, :total)

        :telemetry.execute(
          [:arc, :connection, :close],
          %{duration: now() - socket.at},
          %{app_id: socket.app_id}
        )

        {:noreply, sockets}
    end
  end

  defp join_channel(app_id, channel, type) do
    if incr(@channels, {app_id, channel}, 1) == 1 do
      :telemetry.execute([:arc, :channel, :occupied], %{count: 1}, %{app_id: app_id, type: type})
      Arc.Webhooks.Events.occupied(app_id, channel)
    end
  end

  defp leave_channel(app_id, channel, type) do
    if decr(@channels, {app_id, channel}) == 0 do
      :telemetry.execute([:arc, :channel, :vacated], %{count: 1}, %{app_id: app_id, type: type})
      Arc.Webhooks.Events.vacated(app_id, channel)
    end
  end

  defp incr(table, key, by), do: :ets.update_counter(table, key, by, {key, 0})

  defp decr(table, key) do
    count = :ets.update_counter(table, key, {2, -1, 0, 0}, {key, 1})
    # Remove the row only if it is still zero; a concurrent increment keeps it.
    if count == 0, do: :ets.select_delete(table, [{{key, 0}, [], [true]}])
    count
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp shard_count, do: System.schedulers_online()
  defp shard_name(index), do: :"#{__MODULE__}.#{index}"
  defp shard_for(pid), do: shard_name(:erlang.phash2(pid, shard_count()))
end
