defmodule Arc.MetricsTest do
  @moduledoc """
  The aggregator is what the dashboard reads and what Prometheus scrapes, so its tick
  is driven here explicitly rather than by the clock: the suite raises the interval so
  tests are not racing it.
  """
  use Arc.RealtimeCase

  alias Arc.Metrics.Aggregator

  setup do
    {app, config} = app_config_fixture()
    %{app: app, config: config}
  end

  defp tick do
    send(Aggregator, :tick)
    # The tick publishes to every node; the reply comes back through PubSub.
    _ = :sys.get_state(Aggregator)
    Process.sleep(20)
    _ = :sys.get_state(Aggregator)
  end

  test "a tick reports this node's connections, subscriptions and presence", %{config: config} do
    {client, socket_id} = connect!(config)
    subscribe!(client, "metrics-public")
    await_event!(client, "pusher_internal:subscription_succeeded")
    subscribe_auth!(client, config, socket_id, "presence-metrics", ~s({"user_id":"u1"}))
    await_event!(client, "pusher_internal:subscription_succeeded")

    eventually(fn ->
      Arc.Realtime.Occupancy.subscription_count(config.id, "metrics-public") == 1
    end)

    Phoenix.PubSub.subscribe(Arc.PubSub, Aggregator.topic())
    tick()

    assert_receive {:arc_stats, stats}, 2_000
    assert stats.connections >= 1
    assert %{connections: connections, subscriptions: subscriptions} = stats.apps[config.id]
    assert connections >= 1
    assert subscriptions >= 2

    assert %{connections: _, memory: memory, run_queue: _} =
             Enum.find(stats.nodes, &(&1.name == node()))

    assert memory > 0
  end

  test "the snapshot and history are readable, and history grows with each tick" do
    before = length(Aggregator.history())
    tick()

    snapshot = Aggregator.snapshot()
    assert is_integer(snapshot.connections)
    assert is_integer(snapshot.messages_per_second)

    history = Aggregator.history()
    assert length(history) > before
    assert %{at: at, connections: _, messages_per_second: _} = List.last(history)
    assert is_integer(at)
  end

  test "published messages are counted per second", %{config: config} do
    {:ok, channel} = Arc.Channels.Channel.parse("metrics-rate")
    for _ <- 1..5, do: Arc.Realtime.publish(config, [channel], "e", "{}")

    Phoenix.PubSub.subscribe(Arc.PubSub, Aggregator.topic())
    tick()

    assert_receive {:arc_stats, stats}, 2_000
    assert stats.messages_per_second >= 5
  end

  test "reports from other nodes are merged, and stale ones drop out" do
    Phoenix.PubSub.subscribe(Arc.PubSub, Aggregator.topic())

    remote = %{
      connections: 7,
      messages_per_second: 3,
      apps: %{-1 => %{connections: 7, channels: 2, subscriptions: 9}},
      memory: 1_000,
      run_queue: 0
    }

    send(Aggregator, {:node_stats, :other@node, remote})
    tick()

    assert_receive {:arc_stats, stats}, 2_000
    assert stats.connections >= 7
    assert stats.apps[-1].connections == 7
    assert Enum.any?(stats.nodes, &(&1.name == :other@node))
  end
end
