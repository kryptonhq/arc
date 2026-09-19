defmodule Arc.ClusterTest do
  @moduledoc """
  Three nodes in one run: this test node plus two peers. Run with

      mix test --only cluster
  """
  use Arc.RealtimeCase

  alias Arc.Channels.Channel
  alias Arc.Test.Cluster

  @moduletag :cluster
  @moduletag timeout: 120_000

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(Arc.Repo, :auto)
    Cluster.ensure_distributed()
    {peer2, node2} = Cluster.start_node(:arc_node2, 4102)
    {peer3, node3} = Cluster.start_node(:arc_node3, 4103)

    on_exit(fn ->
      for peer <- [peer2, peer3] do
        try do
          :peer.stop(peer)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{node2: node2, node3: node3}
  end

  setup do
    {app, config} = app_config_fixture(%{"client_events_enabled" => true})
    on_exit(fn -> Arc.Apps.delete_app(app) end)
    # The config reaches the peers over the cache broadcast.
    eventually(fn ->
      Enum.all?(Node.list(), &match?(%{}, :erpc.call(&1, Arc.Apps.Cache, :get, [config.id])))
    end)

    %{config: config}
  end

  test "the nodes form one cluster", %{node2: node2, node3: node3} do
    assert node2 in Node.list() and node3 in Node.list()
    assert node3 in :erpc.call(node2, Node, :list, [])
  end

  test "a publish on node 1 reaches a subscriber on node 3", %{config: config} do
    {client, _} = connect!(config, "protocol=7", 4103)
    subscribe!(client, "cross")
    await_event!(client, "pusher_internal:subscription_succeeded")

    {:ok, channel} = Channel.parse("cross")
    Arc.Realtime.publish(config, [channel], "hello", ~s({"from":"node1"}))
    assert %{"event" => "hello", "data" => ~s({"from":"node1"})} = next_frame!(client)
  end

  test "client events and socket-id exclusion work across nodes", %{config: config} do
    {a, a_id} = connect!(config, "protocol=7", 4102)
    {b, b_id} = connect!(config, "protocol=7", 4103)
    subscribe_auth!(a, config, a_id, "private-x")
    subscribe_auth!(b, config, b_id, "private-x")
    await_event!(a, "pusher_internal:subscription_succeeded")
    await_event!(b, "pusher_internal:subscription_succeeded")

    WsClient.send_json(a, %{event: "client-ping", channel: "private-x", data: %{}})
    assert %{"event" => "client-ping"} = next_frame!(b)
    refute_frame(a)
  end

  test "channel queries and counts are cluster-wide", %{config: config} do
    {a, _} = connect!(config, "protocol=7", 4102)
    {b, _} = connect!(config, "protocol=7", 4103)
    for c <- [a, b], do: subscribe!(c, "counted")
    await_event!(a, "pusher_internal:subscription_succeeded")
    await_event!(b, "pusher_internal:subscription_succeeded")

    eventually(fn -> Arc.Realtime.subscription_count(config.id, "counted") == 2 end)
    assert Arc.Realtime.occupied_channels(config.id)["counted"] == 2
    assert Arc.Realtime.connection_count(config.id) >= 2
  end

  test "terminate_user_connections reaches every node", %{config: config} do
    clients =
      for port <- [4102, 4103] do
        {client, socket_id} = connect!(config, "protocol=7", port)
        user_data = ~s({"id":"everywhere"})
        auth = Arc.Channels.Auth.sign_user(config, socket_id, user_data)

        WsClient.send_json(client, %{
          event: "pusher:signin",
          data: %{auth: auth, user_data: user_data}
        })

        await_event!(client, "pusher:signin_success")
        client
      end

    Arc.Realtime.terminate_user_connections(config.id, "everywhere")
    for client <- clients, do: assert({4300, _} = await_close!(client))
  end

  test "presence converges across nodes and after a partition", %{
    config: config,
    node2: node2,
    node3: node3
  } do
    join = fn port, user ->
      {client, socket_id} = connect!(config, "protocol=7", port)

      subscribe_auth!(
        client,
        config,
        socket_id,
        "presence-cluster",
        Jason.encode!(%{user_id: user})
      )

      await_event!(client, "pusher_internal:subscription_succeeded")
      client
    end

    alice = join.(4102, "alice")
    _bob = join.(4103, "bob")

    assert %{"user_id" => "bob"} =
             await_event!(alice, "pusher_internal:member_added", 3_000) |> decode_data()

    members = fn node ->
      :erpc.call(node, Arc.Realtime, :user_ids, [config.id, "presence-cluster"]) |> Enum.sort()
    end

    eventually(fn -> members.(node()) == ["alice", "bob"] end, 3_000)

    # Partition node 3 from the others, let a member join on the isolated side, heal.
    true = :erpc.call(node2, Node, :disconnect, [node3])
    true = Node.disconnect(node3)

    eventually(fn ->
      node3 not in Node.list() and node3 not in :erpc.call(node2, Node, :list, [])
    end)

    _carol = join.(4103, "carol")
    true = Node.connect(node3)
    true = :erpc.call(node2, Node, :connect, [node3])

    eventually(
      fn -> Enum.all?([node(), node2, node3], &(members.(&1) == ["alice", "bob", "carol"])) end,
      10_000
    )

    assert %{"user_id" => "carol"} =
             await_event!(alice, "pusher_internal:member_added", 10_000) |> decode_data()
  end

  test "killing a node removes its members from presence", %{config: config, node2: node2} do
    {peer4, node4} = Cluster.start_node(:arc_node4, 4104)
    eventually(fn -> match?(%{}, :erpc.call(node4, Arc.Apps.Cache, :get, [config.id])) end)

    {watcher, socket_id} = connect!(config, "protocol=7", 4102)
    subscribe_auth!(watcher, config, socket_id, "presence-kill", ~s({"user_id":"watcher"}))
    await_event!(watcher, "pusher_internal:subscription_succeeded")

    {doomed, doomed_id} = connect!(config, "protocol=7", 4104)
    subscribe_auth!(doomed, config, doomed_id, "presence-kill", ~s({"user_id":"doomed"}))
    await_event!(doomed, "pusher_internal:subscription_succeeded")
    await_event!(watcher, "pusher_internal:member_added", 3_000)

    :peer.stop(peer4)

    assert %{"user_id" => "doomed"} =
             await_event!(watcher, "pusher_internal:member_removed", 15_000) |> decode_data()

    assert :erpc.call(node2, Arc.Realtime, :user_ids, [config.id, "presence-kill"]) == ["watcher"]
  end
end
