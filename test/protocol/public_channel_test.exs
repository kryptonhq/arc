defmodule Arc.Protocol.PublicChannelTest do
  use Arc.RealtimeCase

  alias Arc.Realtime

  setup do
    {_app, config} = app_config_fixture()
    %{config: config}
  end

  test "subscribe, receive, unsubscribe", %{config: config} do
    {client, _} = connect!(config)
    subscribe!(client, "news")

    assert %{
             "event" => "pusher_internal:subscription_succeeded",
             "channel" => "news",
             "data" => "{}"
           } = next_frame!(client)

    {:ok, news} = Arc.Channels.Channel.parse("news")
    :ok = Realtime.publish(config, [news], "headline", ~s({"title":"hi"}))

    assert %{"event" => "headline", "channel" => "news", "data" => ~s({"title":"hi"})} =
             next_frame!(client)

    WsClient.send_json(client, %{event: "pusher:unsubscribe", data: %{channel: "news"}})

    # Unsubscribe has no acknowledgement, so wait for the registry, which is what
    # decides delivery. Occupancy counts follow it asynchronously, and a count of zero
    # can mean "not counted yet" rather than "no longer subscribed".
    eventually(fn ->
      Registry.lookup(Arc.Realtime.Registries.Channels, {config.id, "news"}) == []
    end)

    :ok = Realtime.publish(config, [news], "headline", "{}")
    refute_frame(client)
  end

  test "data is delivered as the exact string published, never re-encoded", %{config: config} do
    {client, _} = connect!(config)
    subscribe!(client, "raw")
    next_frame!(client)

    {:ok, raw} = Arc.Channels.Channel.parse("raw")
    payload = ~s({"b": 1,  "a": [1, 2]})
    :ok = Realtime.publish(config, [raw], "e", payload)
    assert %{"data" => ^payload} = next_frame!(client)
  end

  test "resubscribing is idempotent", %{config: config} do
    {client, _} = connect!(config)
    subscribe!(client, "again")
    next_frame!(client)
    subscribe!(client, "again")
    assert %{"event" => "pusher_internal:subscription_succeeded"} = next_frame!(client)
    eventually(fn -> Arc.Realtime.Occupancy.subscription_count(config.id, "again") == 1 end)
  end

  test "unsubscribing from a channel never joined is a no-op", %{config: config} do
    {client, _} = connect!(config)
    WsClient.send_json(client, %{event: "pusher:unsubscribe", data: %{channel: "never"}})
    refute_frame(client)
  end

  test "invalid channel names are rejected with a subscription error", %{config: config} do
    {client, _} = connect!(config)
    subscribe!(client, "bad name!")

    frame = next_frame!(client)
    assert frame["event"] == "pusher:subscription_error"
    assert frame["channel"] == "bad name!"
    assert %{"type" => "InvalidChannel", "status" => 400} = decode_data(frame)
  end

  test "socket_id exclusion skips the originating connection", %{config: config} do
    {a, a_id} = connect!(config)
    {b, _} = connect!(config)
    for client <- [a, b], do: subscribe!(client, "room")
    next_frame!(a)
    next_frame!(b)

    {:ok, room} = Arc.Channels.Channel.parse("room")
    :ok = Realtime.publish(config, [room], "moved", "{}", a_id)

    assert %{"event" => "moved"} = next_frame!(b)
    refute_frame(a)
  end

  test "events are isolated between apps", %{config: config} do
    {_other_app, other} = app_config_fixture()
    {client, _} = connect!(config)
    subscribe!(client, "shared-name")
    next_frame!(client)

    {:ok, channel} = Arc.Channels.Channel.parse("shared-name")
    :ok = Realtime.publish(other, [channel], "e", "{}")
    refute_frame(client)
  end

  test "user channels require signing in as that user", %{config: config} do
    {client, _} = connect!(config)
    subscribe!(client, "#server-to-user-1")
    frame = next_frame!(client)
    assert frame["event"] == "pusher:subscription_error"
    assert %{"status" => 403} = decode_data(frame)
  end
end
