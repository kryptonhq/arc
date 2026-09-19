defmodule Arc.FailureTest do
  @moduledoc """
  Each scenario must degrade in a specified way rather than take the node down.
  Slow consumers, malformed frames, and failing webhook endpoints are covered in the
  protocol and webhook suites; these are the remaining ones.
  """
  use Arc.RealtimeCase

  import ExUnit.CaptureLog

  alias Arc.Channels.Channel

  setup do
    {app, config} = app_config_fixture(%{"client_events_enabled" => true})
    %{app: app, config: config}
  end

  defp healthy!(config) do
    {client, _} = connect!(config)
    WsClient.send_json(client, %{event: "pusher:ping", data: %{}})
    assert %{"event" => "pusher:pong"} = next_frame!(client)
    WsClient.close(client)
  end

  test "a frame announcing 100 MB is refused from its header alone", %{config: config} do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", 4002, [:binary, active: false])
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(socket, [
        "GET /app/#{config.key}?protocol=7 HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n",
        "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
      ])

    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    assert response =~ "101"

    # FIN + text opcode, masked, 64-bit length of 100 MB, then only a few bytes.
    length = 100 * 1024 * 1024
    :ok = :gen_tcp.send(socket, <<1::1, 0::3, 1::4, 1::1, 127::7, length::64, 0::32, "tiny">>)

    assert await_tcp_close(socket) == :closed
    healthy!(config)
  end

  defp await_tcp_close(socket) do
    case :gen_tcp.recv(socket, 0, 3_000) do
      {:ok, _data} -> await_tcp_close(socket)
      {:error, :closed} -> :closed
      {:error, other} -> other
    end
  end

  test "an app removed while connected closes its sockets with 4001 on their next action", %{
    config: config
  } do
    {subscriber, _} = connect!(config)
    {sender, sender_id} = connect!(config)
    {signer, _} = connect!(config)
    subscribe_auth!(sender, config, sender_id, "private-gone")
    await_event!(sender, "pusher_internal:subscription_succeeded")

    Arc.Apps.Cache.delete(config.id)

    subscribe!(subscriber, "anything")
    assert {4001, _} = await_close!(subscriber)

    WsClient.send_json(sender, %{event: "client-x", channel: "private-gone", data: %{}})
    assert {4001, _} = await_close!(sender)

    WsClient.send_json(signer, %{
      event: "pusher:signin",
      data: %{auth: "x:y", user_data: ~s({"id":"u"})}
    })

    assert {4001, _} = await_close!(signer)
  end

  test "an API body over 10 MB is refused with 413", %{config: config} do
    body = String.duplicate("x", 10_485_761)
    path = signed_path(config, "POST", "/apps/#{config.id}/events", body)
    resp = Req.post!("http://localhost:4002" <> path, body: body, retry: false)
    assert resp.status == 413
    healthy!(config)
  end

  test "the data plane keeps working while Postgres is unavailable", %{config: config} do
    {client, _} = connect!(config)
    subscribe!(client, "no-db")
    await_event!(client, "pusher_internal:subscription_succeeded")

    :ok = Supervisor.terminate_child(Arc.Supervisor, Arc.Repo)

    try do
      # Handshakes, subscriptions, and publishes never touch the database.
      {other, _} = connect!(config)
      subscribe!(other, "no-db")
      await_event!(other, "pusher_internal:subscription_succeeded")

      body = Jason.encode!(%{name: "still-up", channel: "no-db", data: "{}"})

      resp =
        Req.post!(
          "http://localhost:4002" <>
            signed_path(config, "POST", "/apps/#{config.id}/events", body),
          body: body,
          retry: false
        )

      assert resp.status == 200
      assert %{"event" => "still-up"} = await_event!(client, "still-up")
      assert %{"event" => "still-up"} = await_event!(other, "still-up")

      # Work that needs the database fails softly and is logged.
      log =
        capture_log(fn ->
          {:ok, pid} = Arc.Webhooks.Deliverer.enqueue(config.id, 1, %{events: []})
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
          assert Arc.Webhooks.Scheduler.poll_now() == 0
        end)

      assert log =~ "webhook"
      assert Process.alive?(Process.whereis(Arc.Apps.Cache))
    after
      {:ok, _} = Supervisor.restart_child(Arc.Supervisor, Arc.Repo)
    end
  end

  test "rapid connect/disconnect churn leaves no counts behind", %{config: config} do
    for _ <- 1..30 do
      {client, _} = connect!(config)
      subscribe!(client, "churn")
      WsClient.close(client)
    end

    eventually(fn ->
      Arc.Realtime.Occupancy.connection_count(config.id) == 0 and
        Arc.Realtime.Occupancy.subscription_count(config.id, "churn") == 0
    end)

    {:ok, channel} = Channel.parse("churn")
    assert :ok = Arc.Realtime.publish(config, [channel], "e", "{}")
  end
end
