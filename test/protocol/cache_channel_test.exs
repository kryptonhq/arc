defmodule Arc.Protocol.CacheChannelTest do
  use Arc.RealtimeCase

  alias Arc.Channels.Channel
  alias Arc.Realtime

  setup do
    {_app, config} = app_config_fixture()
    %{config: config}
  end

  test "a new subscriber with nothing retained gets cache_miss", %{config: config} do
    {client, _} = connect!(config)
    subscribe!(client, "cache-price")
    assert %{"event" => "pusher_internal:subscription_succeeded"} = next_frame!(client)
    assert %{"event" => "pusher:cache_miss", "channel" => "cache-price"} = next_frame!(client)
  end

  test "a late subscriber receives the last event right after subscription_succeeded", %{
    config: config
  } do
    {:ok, channel} = Channel.parse("cache-price")
    Realtime.publish(config, [channel], "tick", ~s({"v":1}))
    Realtime.publish(config, [channel], "tick", ~s({"v":2}))

    {client, _} = connect!(config)
    subscribe!(client, "cache-price")
    assert %{"event" => "pusher_internal:subscription_succeeded"} = next_frame!(client)

    assert %{"event" => "tick", "channel" => "cache-price", "data" => ~s({"v":2})} =
             next_frame!(client)

    refute_frame(client)
  end

  test "retained events expire", %{config: config} do
    original = Application.fetch_env!(:arc, Arc.Realtime)
    Application.put_env(:arc, Arc.Realtime, Keyword.put(original, :cache_ttl, 0))
    on_exit(fn -> Application.put_env(:arc, Arc.Realtime, original) end)

    {:ok, channel} = Channel.parse("cache-old")
    Realtime.publish(config, [channel], "tick", "{}")
    Process.sleep(5)

    {client, _} = connect!(config)
    subscribe!(client, "cache-old")
    next_frame!(client)
    assert %{"event" => "pusher:cache_miss"} = next_frame!(client)
  end

  test "non-cache channels never replay", %{config: config} do
    {:ok, channel} = Channel.parse("plain")
    Realtime.publish(config, [channel], "tick", "{}")

    {client, _} = connect!(config)
    subscribe!(client, "plain")
    next_frame!(client)
    refute_frame(client)
  end

  test "the sweeper removes expired entries" do
    Arc.Realtime.ChannelCache.put(-5, "cache-x", "frame")
    original = Application.fetch_env!(:arc, Arc.Realtime)
    Application.put_env(:arc, Arc.Realtime, Keyword.put(original, :cache_ttl, 0))
    on_exit(fn -> Application.put_env(:arc, Arc.Realtime, original) end)
    Process.sleep(5)

    send(Arc.Realtime.ChannelCache, :sweep)
    _ = :sys.get_state(Arc.Realtime.ChannelCache)
    assert :ets.lookup(:arc_channel_cache, {-5, "cache-x"}) == []

    Arc.Realtime.ChannelCache.put(-6, "cache-y", "frame")
    Arc.Realtime.ChannelCache.delete_app(-6)
    assert :ets.lookup(:arc_channel_cache, {-6, "cache-y"}) == []
  end
end
