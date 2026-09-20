defmodule Arc.Metrics.Aggregator do
  @moduledoc """
  Once a second, reads this node's counters, emits them as telemetry gauges for the
  Prometheus exporter, and shares them with the rest of the cluster over PubSub. Each
  node keeps the latest numbers from every node and publishes the cluster-wide
  snapshot on the local `"arc:stats"` topic, which the dashboard subscribes to.

  The dashboard never queries registries or counters itself, so a dashboard left open
  cannot slow the data plane.
  """
  use GenServer

  alias Arc.Presence
  alias Arc.Realtime.Occupancy

  @nodes_topic "arc:stats:nodes"
  @topic "arc:stats"
  @default_interval 1_000
  @stale_after 5_000
  # Two minutes of per-second snapshots, so a dashboard opened now can draw the
  # recent past instead of starting from an empty chart.
  @history 120

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The dashboard's topic."
  def topic, do: @topic

  @doc "The latest cluster snapshot."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Recent snapshots, oldest first, for charting."
  def history, do: GenServer.call(__MODULE__, :history)

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Arc.PubSub, @nodes_topic)

    :telemetry.attach(
      {__MODULE__, self()},
      [:arc, :message, :sent],
      &__MODULE__.handle_message_event/4,
      counter_ref()
    )

    Process.send_after(self(), :tick, interval())
    {:ok, %{nodes: %{}, last_sent: 0, snapshot: empty_snapshot(), history: []}}
  end

  @doc false
  def handle_message_event(_event, %{count: count}, _meta, ref), do: :counters.add(ref, 1, count)

  defp counter_ref do
    case :persistent_term.get({__MODULE__, :counter}, nil) do
      nil ->
        ref = :counters.new(1, [:write_concurrency])
        :persistent_term.put({__MODULE__, :counter}, ref)
        ref

      ref ->
        ref
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}
  def handle_call(:history, _from, state), do: {:reply, Enum.reverse(state.history), state}

  @impl true
  def handle_info(:tick, state) do
    sent = :counters.get(counter_ref(), 1)
    node_stats = collect(max(sent - state.last_sent, 0))
    Phoenix.PubSub.broadcast(Arc.PubSub, @nodes_topic, {:node_stats, node(), node_stats})

    Process.send_after(self(), :tick, interval())
    {:noreply, %{state | last_sent: sent}}
  end

  def handle_info({:node_stats, from, stats}, state) do
    now = System.monotonic_time(:millisecond)

    nodes =
      state.nodes
      |> Map.put(from, Map.put(stats, :received_at, now))
      |> Map.reject(fn {_, s} -> now - s.received_at > @stale_after end)

    snapshot = build_snapshot(nodes)

    history =
      if from == node() do
        Phoenix.PubSub.local_broadcast(Arc.PubSub, @topic, {:arc_stats, snapshot})
        [sample(snapshot) | state.history] |> Enum.take(@history)
      else
        state.history
      end

    {:noreply, %{state | nodes: nodes, snapshot: snapshot, history: history}}
  end

  defp collect(messages_per_second) do
    connections = Occupancy.connections_by_app()
    channel_stats = Occupancy.channel_stats()
    presence = Presence.members_by_app()
    node_name = Atom.to_string(node())

    apps =
      (Map.keys(connections) ++ Map.keys(channel_stats) ++ Arc.Apps.Cache.ids())
      |> Enum.uniq()
      |> Map.new(fn app_id ->
        {channels, subscriptions} = Map.get(channel_stats, app_id, {0, 0})
        conns = Map.get(connections, app_id, 0)
        members = Map.get(presence, app_id, 0)

        :telemetry.execute(
          [:arc, :stats, :app],
          %{connections: conns, subscriptions: subscriptions, presence_members: members},
          %{app_id: app_id, node: node_name}
        )

        {app_id, %{connections: conns, channels: channels, subscriptions: subscriptions}}
      end)

    for {{app_id, type}, count} <- Occupancy.channels_by_type() do
      :telemetry.execute([:arc, :stats, :channels], %{count: count}, %{app_id: app_id, type: type})
    end

    %{
      connections: Occupancy.total_connections(),
      messages_per_second: messages_per_second,
      apps: apps,
      memory: :erlang.memory(:total),
      run_queue: :erlang.statistics(:total_run_queue_lengths)
    }
  end

  defp build_snapshot(nodes) do
    apps =
      Enum.reduce(nodes, %{}, fn {_node, stats}, acc ->
        Map.merge(acc, stats.apps, fn _id, a, b ->
          %{
            connections: a.connections + b.connections,
            channels: max(a.channels, b.channels),
            subscriptions: a.subscriptions + b.subscriptions
          }
        end)
      end)

    %{
      connections: nodes |> Map.values() |> Enum.map(& &1.connections) |> Enum.sum(),
      messages_per_second:
        nodes |> Map.values() |> Enum.map(& &1.messages_per_second) |> Enum.sum(),
      apps: apps,
      nodes:
        nodes
        |> Enum.map(fn {name, s} ->
          %{name: name, connections: s.connections, memory: s.memory, run_queue: s.run_queue}
        end)
        |> Enum.sort_by(& &1.name)
    }
  end

  # How often a node publishes its numbers. Tests raise this so an injected snapshot
  # is not overwritten by a real one mid-assertion.
  defp interval do
    Application.get_env(:arc, Arc.Metrics, []) |> Keyword.get(:interval, @default_interval)
  end

  defp sample(snapshot) do
    %{
      at: System.system_time(:second),
      connections: snapshot.connections,
      messages_per_second: snapshot.messages_per_second
    }
  end

  defp empty_snapshot, do: %{connections: 0, messages_per_second: 0, apps: %{}, nodes: []}
end
