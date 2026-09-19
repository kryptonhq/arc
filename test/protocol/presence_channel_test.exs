defmodule Arc.Protocol.PresenceChannelTest do
  use Arc.RealtimeCase

  alias Arc.Apps

  setup do
    {app, config} = app_config_fixture()
    %{app: app, config: config}
  end

  defp join!(config, channel, user_id, info \\ nil) do
    {client, socket_id} = connect!(config)

    data =
      Jason.encode!(if info, do: %{user_id: user_id, user_info: info}, else: %{user_id: user_id})

    subscribe_auth!(client, config, socket_id, channel, data)
    {client, socket_id}
  end

  test "subscription_succeeded carries the presence payload", %{config: config} do
    {alice, _} = join!(config, "presence-room", "alice", %{"name" => "Alice"})
    frame = await_event!(alice, "pusher_internal:subscription_succeeded")
    assert frame["channel"] == "presence-room"

    assert %{
             "presence" => %{
               "ids" => ["alice"],
               "hash" => %{"alice" => %{"name" => "Alice"}},
               "count" => 1
             }
           } =
             decode_data(frame)
  end

  test "members see each other join and leave", %{config: config} do
    {alice, _} = join!(config, "presence-room", "alice", %{"name" => "Alice"})
    await_event!(alice, "pusher_internal:subscription_succeeded")

    {bob, _} = join!(config, "presence-room", "bob")
    bob_joined = await_event!(bob, "pusher_internal:subscription_succeeded") |> decode_data()
    assert Enum.sort(bob_joined["presence"]["ids"]) == ["alice", "bob"]
    assert bob_joined["presence"]["count"] == 2

    added = await_event!(alice, "pusher_internal:member_added")
    assert added["channel"] == "presence-room"
    assert decode_data(added) == %{"user_id" => "bob"}

    # The joiner does not receive its own member_added.
    refute_frame(bob)

    WsClient.close(bob)
    removed = await_event!(alice, "pusher_internal:member_removed")
    assert decode_data(removed) == %{"user_id" => "bob"}
  end

  test "a second connection for the same user id produces no duplicate events", %{config: config} do
    {alice, _} = join!(config, "presence-room", "alice")
    await_event!(alice, "pusher_internal:subscription_succeeded")

    {bob1, _} = join!(config, "presence-room", "bob")
    await_event!(bob1, "pusher_internal:subscription_succeeded")
    await_event!(alice, "pusher_internal:member_added")

    {bob2, _} = join!(config, "presence-room", "bob")
    second = await_event!(bob2, "pusher_internal:subscription_succeeded") |> decode_data()
    assert second["presence"]["count"] == 2
    refute_frame(alice)

    # Removal fires only when the last connection for the user leaves.
    WsClient.close(bob1)
    refute_frame(alice, 300)

    WsClient.close(bob2)

    assert %{"user_id" => "bob"} =
             await_event!(alice, "pusher_internal:member_removed") |> decode_data()
  end

  test "unsubscribing removes the member", %{config: config} do
    {alice, _} = join!(config, "presence-room", "alice")
    await_event!(alice, "pusher_internal:subscription_succeeded")
    {bob, _} = join!(config, "presence-room", "bob")
    await_event!(bob, "pusher_internal:subscription_succeeded")
    await_event!(alice, "pusher_internal:member_added")

    WsClient.send_json(bob, %{event: "pusher:unsubscribe", data: %{channel: "presence-room"}})

    assert %{"user_id" => "bob"} =
             await_event!(alice, "pusher_internal:member_removed") |> decode_data()
  end

  test "numeric user ids are accepted as strings", %{config: config} do
    {client, socket_id} = connect!(config)
    data = ~s({"user_id":42})
    subscribe_auth!(client, config, socket_id, "presence-n", data)

    assert %{"presence" => %{"ids" => ["42"]}} =
             await_event!(client, "pusher_internal:subscription_succeeded") |> decode_data()
  end

  test "channel_data is validated", %{config: config} do
    {client, socket_id} = connect!(config)

    subscribe_auth!(client, config, socket_id, "presence-x")
    assert %{"status" => 400, "type" => "InvalidChannelData"} = decode_data(next_frame!(client))

    data = ~s({"name":"no id"})
    subscribe_auth!(client, config, socket_id, "presence-x", data)
    assert %{"status" => 400} = decode_data(next_frame!(client))

    for bad_id <- [~s({"user_id":""}), ~s({"user_id":1.5}), ~s({"user_id":null})] do
      subscribe_auth!(client, config, socket_id, "presence-x", bad_id)
      assert %{"status" => 400} = decode_data(next_frame!(client))
    end

    data = Jason.encode!(%{user_id: "u", user_info: %{"blob" => String.duplicate("a", 10_300)}})
    subscribe_auth!(client, config, socket_id, "presence-x", data)
    assert %{"status" => 400, "error" => error} = decode_data(next_frame!(client))
    assert error =~ "10240"
  end

  test "a signature over different channel_data is rejected", %{config: config} do
    {client, socket_id} = connect!(config)
    auth = Arc.Channels.Auth.sign_channel(config, socket_id, "presence-x", ~s({"user_id":"a"}))
    subscribe!(client, "presence-x", %{auth: auth, channel_data: ~s({"user_id":"admin"})})
    assert %{"status" => 401} = decode_data(next_frame!(client))
  end

  test "the member ceiling rejects new user ids but not existing ones", %{app: app} do
    {:ok, _} = Apps.update_app(app, %{"max_presence_members" => 2})
    config = Apps.get_config(app.id)

    {a, _} = join!(config, "presence-full", "a")
    await_event!(a, "pusher_internal:subscription_succeeded")
    {b, _} = join!(config, "presence-full", "b")
    await_event!(b, "pusher_internal:subscription_succeeded")

    {c, _} = join!(config, "presence-full", "c")
    frame = await_event!(c, "pusher:subscription_error")
    assert %{"type" => "LimitReached", "status" => 403} = decode_data(frame)

    {a2, _} = join!(config, "presence-full", "a")

    assert %{"presence" => %{"count" => 2}} =
             await_event!(a2, "pusher_internal:subscription_succeeded") |> decode_data()
  end

  test "the ceiling can be disabled per app", %{app: app} do
    {:ok, _} =
      Apps.update_app(app, %{"max_presence_members" => 1, "enable_presence_limits" => false})

    config = Apps.get_config(app.id)

    {a, _} = join!(config, "presence-open", "a")
    await_event!(a, "pusher_internal:subscription_succeeded")
    {b, _} = join!(config, "presence-open", "b")

    assert %{"presence" => %{"count" => 2}} =
             await_event!(b, "pusher_internal:subscription_succeeded") |> decode_data()
  end

  test "presence-cache channels replay and report presence", %{config: config} do
    {client, _} = join!(config, "presence-cache-room", "a")

    assert %{"presence" => %{"count" => 1}} =
             await_event!(client, "pusher_internal:subscription_succeeded") |> decode_data()

    assert %{"event" => "pusher:cache_miss"} = next_frame!(client)
  end

  test "crashing a socket process removes its membership", %{config: config} do
    {alice, _} = join!(config, "presence-crash", "alice")
    await_event!(alice, "pusher_internal:subscription_succeeded")
    {bob, bob_socket} = join!(config, "presence-crash", "bob")
    await_event!(bob, "pusher_internal:subscription_succeeded")
    await_event!(alice, "pusher_internal:member_added")

    [{pid, _}] =
      Registry.lookup(Arc.Realtime.Registries.Channels, {config.id, "presence-crash"})
      |> Enum.filter(fn {_pid, socket_id} -> socket_id == bob_socket end)

    Process.exit(pid, :kill)

    assert %{"user_id" => "bob"} =
             await_event!(alice, "pusher_internal:member_removed") |> decode_data()

    eventually(fn ->
      Arc.Realtime.Occupancy.subscription_count(config.id, "presence-crash") == 1
    end)
  end
end
