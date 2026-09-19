defmodule Arc.Protocol.ClientEventsTest do
  use Arc.RealtimeCase

  alias Arc.Apps

  setup do
    {app, _} = app_config_fixture(%{"client_events_enabled" => true})
    %{app: app, config: Apps.get_config(app.id)}
  end

  defp pair!(config, channel) do
    {a, a_id} = connect!(config)
    {b, b_id} = connect!(config)

    for {client, id} <- [{a, a_id}, {b, b_id}] do
      if String.starts_with?(channel, "presence-") do
        subscribe_auth!(client, config, id, channel, Jason.encode!(%{user_id: id}))
      else
        subscribe_auth!(client, config, id, channel)
      end

      await_event!(client, "pusher_internal:subscription_succeeded")
    end

    # Drain member_added between the two.
    if String.starts_with?(channel, "presence-"),
      do: await_event!(a, "pusher_internal:member_added")

    {a, a_id, b, b_id}
  end

  test "delivered to others on private channels, never echoed", %{config: config} do
    {a, _, b, _} = pair!(config, "private-chat")

    WsClient.send_json(a, %{
      event: "client-typing",
      channel: "private-chat",
      data: %{"who" => "a"}
    })

    assert %{"event" => "client-typing", "channel" => "private-chat", "data" => %{"who" => "a"}} =
             next_frame!(b)

    refute Map.has_key?(next_frame_or_nil(a), "event")
  end

  test "on presence channels the sender's user_id is attached", %{config: config} do
    {a, a_id, b, _} = pair!(config, "presence-chat")
    WsClient.send_json(a, %{event: "client-wave", channel: "presence-chat", data: "{}"})
    assert %{"event" => "client-wave", "user_id" => ^a_id, "data" => "{}"} = next_frame!(b)
  end

  test "rejected when the app has client events disabled", %{app: app} do
    {:ok, _} = Apps.update_app(app, %{"client_events_enabled" => false})
    config = Apps.get_config(app.id)
    {a, _, b, _} = pair!(config, "private-chat")

    WsClient.send_json(a, %{event: "client-x", channel: "private-chat", data: %{}})
    assert %{"event" => "pusher:error", "data" => %{"message" => message}} = next_frame!(a)
    assert message =~ "not enabled"
    refute_frame(b)
  end

  test "rejected on public, encrypted, and unsubscribed channels", %{config: config} do
    {client, socket_id} = connect!(config)
    subscribe!(client, "public")
    next_frame!(client)
    subscribe_auth!(client, config, socket_id, "private-encrypted-x")
    next_frame!(client)

    WsClient.send_json(client, %{event: "client-x", channel: "public", data: %{}})
    assert %{"data" => %{"message" => m1}} = next_frame!(client)
    assert m1 =~ "private and presence"

    WsClient.send_json(client, %{event: "client-x", channel: "private-encrypted-x", data: %{}})
    assert %{"event" => "pusher:error"} = next_frame!(client)

    WsClient.send_json(client, %{event: "client-x", channel: "private-other", data: %{}})
    assert %{"data" => %{"message" => m2}} = next_frame!(client)
    assert m2 =~ "joined"

    WsClient.send_json(client, %{event: "client-x", data: %{}})
    assert %{"event" => "pusher:error"} = next_frame!(client)
  end

  test "payloads over the cap are rejected", %{config: config} do
    {a, _, b, _} = pair!(config, "private-big")

    WsClient.send_json(a, %{
      event: "client-big",
      channel: "private-big",
      data: String.duplicate("x", 10_300)
    })

    assert %{"event" => "pusher:error", "data" => %{"message" => message}} = next_frame!(a)
    assert message =~ "10240"
    refute_frame(b)
  end

  test "more than 10 per second is rate limited with 4301 and the connection stays open", %{
    config: config
  } do
    {a, _, b, _} = pair!(config, "private-fast")

    for i <- 1..12 do
      WsClient.send_json(a, %{event: "client-n", channel: "private-fast", data: %{"i" => i}})
    end

    received = collect(b, 300)
    assert length(received) == 10
    assert %{"event" => "pusher:error", "data" => %{"code" => 4301}} = next_frame!(a)

    WsClient.send_json(a, %{event: "pusher:ping", data: %{}})
    assert %{"event" => "pusher:pong"} = await_event!(a, "pusher:pong")
  end

  defp collect(client, timeout, acc \\ []) do
    receive do
      {:frame, ^client, frame} -> collect(client, timeout, [frame | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp next_frame_or_nil(client) do
    receive do
      {:frame, ^client, frame} -> frame
    after
      200 -> %{}
    end
  end
end
