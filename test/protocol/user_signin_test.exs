defmodule Arc.Protocol.UserSigninTest do
  use Arc.RealtimeCase

  alias Arc.Channels.Auth

  setup do
    {_app, config} = app_config_fixture()
    %{config: config}
  end

  defp signin!(client, config, socket_id, user_data) do
    WsClient.send_json(client, %{
      event: "pusher:signin",
      data: %{auth: Auth.sign_user(config, socket_id, user_data), user_data: user_data}
    })
  end

  test "signin_success echoes user_data and enables the user channel", %{config: config} do
    {client, socket_id} = connect!(config)
    user_data = ~s({"id":"u1","name":"Una"})
    signin!(client, config, socket_id, user_data)

    frame = next_frame!(client)
    assert frame["event"] == "pusher:signin_success"
    assert decode_data(frame) == %{"user_data" => user_data}

    subscribe!(client, "#server-to-user-u1")
    assert %{"event" => "pusher_internal:subscription_succeeded"} = next_frame!(client)

    {:ok, channel} = Arc.Channels.Channel.parse("#server-to-user-u1")
    Arc.Realtime.publish(config, [channel], "notice", "{}")
    assert %{"event" => "notice", "channel" => "#server-to-user-u1"} = next_frame!(client)

    subscribe!(client, "#server-to-user-u2")
    assert %{"status" => 403} = decode_data(next_frame!(client))
  end

  test "an invalid signature closes the connection with 4009", %{config: config} do
    {client, _} = connect!(config)

    WsClient.send_json(client, %{
      event: "pusher:signin",
      data: %{auth: "#{config.key}:bad", user_data: ~s({"id":"u"})}
    })

    assert %{"event" => "pusher:error", "data" => %{"code" => 4009}} = next_frame!(client)
    assert {4009, _} = await_close!(client)
  end

  test "user_data without an id is rejected", %{config: config} do
    {client, socket_id} = connect!(config)
    signin!(client, config, socket_id, ~s({"name":"x"}))
    assert {4009, _} = await_close!(client)
  end

  test "missing fields are rejected", %{config: config} do
    {client, _} = connect!(config)
    WsClient.send_json(client, %{event: "pusher:signin", data: %{auth: "x"}})
    assert {4009, _} = await_close!(client)
  end

  test "terminate_connections closes every connection of the user with 4300", %{config: config} do
    {a, a_id} = connect!(config)
    {b, b_id} = connect!(config)
    {other, other_id} = connect!(config)
    signin!(a, config, a_id, ~s({"id":"target"}))
    signin!(b, config, b_id, ~s({"id":"target"}))
    signin!(other, config, other_id, ~s({"id":"bystander"}))
    for c <- [a, b, other], do: await_event!(c, "pusher:signin_success")

    Arc.Realtime.terminate_user_connections(config.id, "target")
    assert {4300, _} = await_close!(a)
    assert {4300, _} = await_close!(b)

    WsClient.send_json(other, %{event: "pusher:ping", data: %{}})
    assert %{"event" => "pusher:pong"} = next_frame!(other)
  end

  test "signing in again replaces the association", %{config: config} do
    {client, socket_id} = connect!(config)
    signin!(client, config, socket_id, ~s({"id":"first"}))
    await_event!(client, "pusher:signin_success")
    signin!(client, config, socket_id, ~s({"id":"second"}))
    await_event!(client, "pusher:signin_success")

    Arc.Realtime.terminate_user_connections(config.id, "first")
    refute_frame(client, 300)

    Arc.Realtime.terminate_user_connections(config.id, "second")
    assert {4300, _} = await_close!(client)
  end
end
