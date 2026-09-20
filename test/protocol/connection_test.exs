defmodule Arc.Protocol.ConnectionTest do
  use Arc.RealtimeCase

  alias Arc.Apps

  setup do
    {app, config} = app_config_fixture()
    %{app: app, config: config}
  end

  describe "handshake" do
    test "emits connection_established with a socket id and activity timeout", %{config: config} do
      {:ok, client} =
        WsClient.connect("/app/#{config.key}?protocol=7&client=js&version=8.4.0&flash=false")

      frame = next_frame!(client)

      assert frame["event"] == "pusher:connection_established"
      assert is_binary(frame["data"]), "data must be a JSON string, not an object"
      data = Jason.decode!(frame["data"])
      assert data["socket_id"] =~ ~r/\A\d+\.\d+\z/
      assert data["activity_timeout"] == 120
    end

    test "socket ids are unique", %{config: config} do
      ids = for _ <- 1..20, do: connect!(config) |> elem(1)
      assert length(Enum.uniq(ids)) == 20
    end

    test "rejects unsupported protocol versions with 4007", %{config: config} do
      {:ok, client} = WsClient.connect("/app/#{config.key}?protocol=6")
      assert %{"event" => "pusher:error", "data" => %{"code" => 4007}} = next_frame!(client)
      assert {4007, _} = await_close!(client)
    end

    test "rejects a missing or empty protocol version with 4008", %{config: config} do
      for path <- ["/app/#{config.key}", "/app/#{config.key}?protocol="] do
        {:ok, client} = WsClient.connect(path)
        assert %{"data" => %{"code" => 4008}} = next_frame!(client)
        assert {4008, _} = await_close!(client)
      end
    end

    test "rejects an unknown app key with 4001" do
      {:ok, client} = WsClient.connect("/app/nope?protocol=7")
      assert %{"data" => %{"code" => 4001, "message" => message}} = next_frame!(client)
      assert message =~ "nope"
      assert {4001, _} = await_close!(client)
    end

    test "rejects a disabled app with 4003", %{app: app, config: config} do
      {:ok, _} = Apps.update_app(app, %{"enabled" => false})
      {:ok, client} = WsClient.connect("/app/#{config.key}?protocol=7")
      assert %{"data" => %{"code" => 4003}} = next_frame!(client)
      assert {4003, _} = await_close!(client)
    end

    test "rejects connections over the app limit with 4004", %{app: app} do
      {:ok, _} = Apps.update_app(app, %{"max_connections" => 1})
      config = Apps.get_config(app.id)
      {_client, _} = connect!(config)
      eventually(fn -> Arc.Realtime.Occupancy.connection_count(app.id) == 1 end)

      {:ok, second} = WsClient.connect("/app/#{config.key}?protocol=7")
      assert %{"data" => %{"code" => 4004}} = next_frame!(second)
      assert {4004, _} = await_close!(second)
    end

    test "rejects connections with 4100 until the app cache is warm", %{config: config} do
      ready = {Arc.Apps.Cache, :ready}
      :persistent_term.put(ready, false)
      on_exit(fn -> :persistent_term.put(ready, true) end)

      {:ok, client} = WsClient.connect("/app/#{config.key}?protocol=7")
      assert %{"data" => %{"code" => 4100, "message" => message}} = next_frame!(client)
      assert message =~ "starting up"
      assert {4100, _} = await_close!(client)
    end

    test "rejects connections over the node limit with 4100", %{config: config} do
      put_realtime(max_connections_per_node: 0)
      {:ok, client} = WsClient.connect("/app/#{config.key}?protocol=7")
      assert %{"data" => %{"code" => 4100}} = next_frame!(client)
      assert {4100, _} = await_close!(client)
    end

    test "plain HTTP requests to the socket path get a 400" do
      {:ok, conn} = Mint.HTTP.connect(:http, "localhost", 4002)
      {:ok, conn, _ref} = Mint.HTTP.request(conn, "GET", "/app/abc", [], nil)
      assert_receive message, 2_000
      {:ok, _conn, responses} = Mint.HTTP.stream(conn, message)
      assert {:status, _, 400} = List.keyfind(responses, :status, 0)
    end
  end

  describe "liveness" do
    test "answers pusher:ping with pusher:pong", %{config: config} do
      {client, _} = connect!(config)
      WsClient.send_json(client, %{event: "pusher:ping", data: %{}})
      assert %{"event" => "pusher:pong", "data" => "{}"} = next_frame!(client)
    end

    test "pings an idle client and closes with 4201 when no pong arrives", %{config: config} do
      put_realtime(activity_timeout: 0, idle_check_interval: 50, pong_timeout: 200)
      {client, _} = connect!(config)
      assert %{"event" => "pusher:ping"} = next_frame!(client, 1_000)
      assert {4201, _} = await_close!(client, 2_000)
    end

    test "WebSocket control frames count as activity and stray messages are ignored", %{
      config: config
    } do
      {client, _} = connect!(config)
      WsClient.send_raw(client, {:ping, "hi"})
      [{pid, _}] = Registry.lookup(Arc.Realtime.Registries.Apps, config.id)
      send(pid, :unexpected_message)
      WsClient.send_json(client, %{event: "pusher:ping", data: %{}})
      assert %{"event" => "pusher:pong"} = await_event!(client, "pusher:pong")
      assert Process.alive?(pid)
    end

    test "any frame from the client counts as a pong", %{config: config} do
      put_realtime(activity_timeout: 0, idle_check_interval: 50, pong_timeout: 300)
      {client, _} = connect!(config)
      assert %{"event" => "pusher:ping"} = next_frame!(client, 1_000)
      WsClient.send_json(client, %{event: "pusher:pong", data: %{}})
      # A fresh ping follows, rather than a close.
      assert %{"event" => "pusher:ping"} = next_frame!(client, 1_000)
    end
  end

  describe "malformed input" do
    test "invalid JSON is reported without closing", %{config: config} do
      {client, _} = connect!(config)
      WsClient.send_raw(client, {:text, "{not json"})

      assert %{"event" => "pusher:error", "data" => %{"code" => nil, "message" => message}} =
               next_frame!(client)

      assert message =~ "JSON"

      WsClient.send_raw(client, {:text, "[1,2]"})
      assert %{"event" => "pusher:error"} = next_frame!(client)

      WsClient.send_raw(client, {:text, ~s({"data":{}})})
      assert %{"event" => "pusher:error"} = next_frame!(client)

      WsClient.send_raw(client, {:text, ~s({"event":"x","channel":5})})
      assert %{"event" => "pusher:error"} = next_frame!(client)

      WsClient.send_raw(client, {:binary, <<1, 2, 3>>})
      assert %{"event" => "pusher:error"} = next_frame!(client)

      WsClient.send_json(client, %{event: "pusher:ping", data: %{}})
      assert %{"event" => "pusher:pong"} = next_frame!(client)
    end

    test "unknown events are reported", %{config: config} do
      {client, _} = connect!(config)
      WsClient.send_json(client, %{event: "pusher:nope", data: %{}})
      assert %{"event" => "pusher:error", "data" => %{"message" => message}} = next_frame!(client)
      assert message =~ "pusher:nope"
    end

    test "subscribe data may be a JSON string, and must be an object", %{config: config} do
      {client, _} = connect!(config)

      WsClient.send_json(client, %{
        event: "pusher:subscribe",
        data: Jason.encode!(%{channel: "a"})
      })

      assert %{"event" => "pusher_internal:subscription_succeeded", "channel" => "a"} =
               next_frame!(client)

      WsClient.send_json(client, %{event: "pusher:subscribe", data: "[]"})
      assert %{"event" => "pusher:error"} = next_frame!(client)

      WsClient.send_json(client, %{event: "pusher:subscribe", data: 5})
      assert %{"event" => "pusher:error"} = next_frame!(client)

      WsClient.send_json(client, %{event: "pusher:subscribe", data: %{}})
      assert %{"event" => "pusher:error"} = next_frame!(client)

      WsClient.send_json(client, %{event: "pusher:unsubscribe", data: %{}})
      assert %{"event" => "pusher:error"} = next_frame!(client)
    end

    test "oversized frames close the connection without affecting others", %{config: config} do
      {client, _} = connect!(config)
      {other, _} = connect!(config)
      WsClient.send_raw(client, {:text, String.duplicate("a", 300_000)})
      assert {code, _} = await_close!(client)
      assert code == 1009

      WsClient.send_json(other, %{event: "pusher:ping", data: %{}})
      assert %{"event" => "pusher:pong"} = next_frame!(other)
    end
  end

  describe "server-side closes" do
    test "deleting an app closes its connections with 4001", %{app: app, config: config} do
      {client, _} = connect!(config)
      {:ok, _} = Apps.delete_app(app)
      assert %{"data" => %{"code" => 4001}} = next_frame!(client)
      assert {4001, _} = await_close!(client)
    end

    test "disabling an app closes its connections with 4003", %{app: app, config: config} do
      {client, _} = connect!(config)
      {:ok, _} = Apps.update_app(app, %{"enabled" => false})
      assert %{"data" => %{"code" => 4003}} = next_frame!(client)
      assert {4003, _} = await_close!(client)
    end

    test "draining the node closes with a reconnect-after-backoff code", %{config: config} do
      {client, _} = connect!(config)
      Arc.Realtime.drain_node()
      assert %{"data" => %{"code" => 4101}} = next_frame!(client)
      assert {4101, _} = await_close!(client)
    end

    test "a slow consumer is closed with 4102", %{app: app, config: config} do
      put_realtime(max_queue_len: 0)
      {client, _} = connect!(config)
      subscribe!(client, "slow")
      await_event!(client, "pusher_internal:subscription_succeeded")

      [{pid, _}] = Registry.lookup(Arc.Realtime.Registries.Apps, app.id)
      :erlang.suspend_process(pid)
      for _ <- 1..3, do: send(pid, {:arc_frame, ~s({"event":"e","channel":"slow","data":"x"})})
      :erlang.resume_process(pid)

      assert {4102, _} = await_close!(client)
    end

    test "close reasons are truncated to fit a close frame", %{config: config} do
      {client, _} = connect!(config)
      [{pid, _}] = Registry.lookup(Arc.Realtime.Registries.Apps, config.id)
      send(pid, {:arc_close, :terminated, String.duplicate("x", 300)})
      assert %{"data" => %{"message" => message}} = next_frame!(client)
      assert byte_size(message) == 300
      assert {4300, reason} = await_close!(client)
      assert byte_size(reason) <= 123
    end
  end

  defp put_realtime(overrides) do
    original = Application.fetch_env!(:arc, Arc.Realtime)
    Application.put_env(:arc, Arc.Realtime, Keyword.merge(original, overrides))
    on_exit(fn -> Application.put_env(:arc, Arc.Realtime, original) end)
  end
end
