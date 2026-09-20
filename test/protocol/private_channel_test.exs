defmodule Arc.Protocol.PrivateChannelTest do
  use Arc.RealtimeCase

  import ExUnit.CaptureLog

  alias Arc.Apps
  alias Arc.Channels.Channel

  setup do
    {app, config} = app_config_fixture()
    %{app: app, config: config}
  end

  test "a valid signature subscribes", %{config: config} do
    {client, socket_id} = connect!(config)
    subscribe_auth!(client, config, socket_id, "private-orders")

    assert %{
             "event" => "pusher_internal:subscription_succeeded",
             "channel" => "private-orders",
             "data" => "{}"
           } =
             next_frame!(client)

    {:ok, channel} = Channel.parse("private-orders")
    Arc.Realtime.publish(config, [channel], "created", "{}")
    assert %{"event" => "created", "channel" => "private-orders"} = next_frame!(client)
  end

  test "a bad signature is rejected with status 401 and no subscription", %{config: config} do
    {client, _socket_id} = connect!(config)
    subscribe!(client, "private-orders", %{auth: "#{config.key}:deadbeef"})

    frame = next_frame!(client)
    assert frame["event"] == "pusher:subscription_error"
    assert frame["channel"] == "private-orders"
    assert %{"type" => "AuthError", "status" => 401, "error" => error} = decode_data(frame)
    assert error =~ "Invalid signature"

    {:ok, channel} = Channel.parse("private-orders")
    Arc.Realtime.publish(config, [channel], "created", "{}")
    refute_frame(client)
  end

  test "rejected subscriptions are logged at info, without the signature", %{config: config} do
    {client, _socket_id} = connect!(config)

    log =
      capture_info(fn ->
        subscribe!(client, "private-logged", %{auth: "#{config.key}:deadbeef"})
        assert %{"status" => 401} = decode_data(next_frame!(client))
      end)

    assert log =~ "subscription rejected"
    assert log =~ "app_id=#{config.id}"
    assert log =~ "status=401"
    refute log =~ "deadbeef"
  end

  test "a signature for another socket is rejected", %{config: config} do
    {client, _} = connect!(config)
    auth = Arc.Channels.Auth.sign_channel(config, "1.1", "private-a")
    subscribe!(client, "private-a", %{auth: auth})
    assert %{"status" => 401} = decode_data(next_frame!(client))
  end

  test "missing auth, wrong key, and malformed auth are rejected", %{config: config} do
    {client, _} = connect!(config)

    subscribe!(client, "private-a")

    assert %{"status" => 401, "error" => "Missing or malformed auth value"} =
             decode_data(next_frame!(client))

    subscribe!(client, "private-a", %{auth: "otherkey:abc"})

    assert %{"status" => 401, "error" => "Auth key does not match this app"} =
             decode_data(next_frame!(client))
  end

  test "a rotated secret stops verifying immediately", %{app: app, config: config} do
    {client, socket_id} = connect!(config)
    {:ok, _app, _new} = Apps.rotate_secret(app)

    # Signed with the old secret.
    subscribe_auth!(client, config, socket_id, "private-a")
    assert %{"status" => 401} = decode_data(next_frame!(client))

    subscribe_auth!(client, Apps.get_config(app.id), socket_id, "private-a")
    assert %{"event" => "pusher_internal:subscription_succeeded"} = next_frame!(client)
  end

  test "private-cache channels require auth", %{config: config} do
    {client, socket_id} = connect!(config)
    subscribe!(client, "private-cache-a")
    assert %{"status" => 401} = decode_data(next_frame!(client))

    subscribe_auth!(client, config, socket_id, "private-cache-a")
    assert %{"event" => "pusher_internal:subscription_succeeded"} = next_frame!(client)
    assert %{"event" => "pusher:cache_miss", "channel" => "private-cache-a"} = next_frame!(client)
  end

  # The suite runs at log level :warning; these assertions need the info messages the
  # doc requires for auth failures, so the level is raised just around the capture.
  defp capture_info(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end
end
