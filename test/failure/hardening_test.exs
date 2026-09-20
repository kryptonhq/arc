defmodule Arc.HardeningTest do
  @moduledoc """
  Operational behaviour a production deployment relies on: drain on shutdown,
  readiness that follows Postgres, and limits on clients that misbehave.
  """
  use Arc.RealtimeCase

  import ExUnit.CaptureLog

  @base "http://localhost:4002"

  setup do
    {app, config} = app_config_fixture()
    %{app: app, config: config}
  end

  defp override(key, value) do
    original = Application.fetch_env!(:arc, Arc.Realtime)
    Application.put_env(:arc, Arc.Realtime, Keyword.put(original, key, value))
    on_exit(fn -> Application.put_env(:arc, Arc.Realtime, original) end)
  end

  defp ready, do: Req.get!(@base <> "/health/ready", retry: false)

  describe "drain" do
    setup do
      on_exit(fn -> Arc.Health.stop_drain() end)
    end

    test "readiness reports 503 first, then clients are closed with 4101", %{config: config} do
      {client, _} = connect!(config)
      assert ready().status == 200

      assert Arc.Application.drain(0) == :ok
      assert %{status: 503, body: "draining"} = ready()
      assert %{"event" => "pusher:error", "data" => %{"code" => 4101}} = next_frame!(client)
      assert {4101, _} = await_close!(client)
    end

    test "a connection during the drain is refused with 4101 straight away", %{config: config} do
      assert Arc.Health.start_drain()
      refute Arc.Health.start_drain(), "start_drain is idempotent"

      {:ok, client} = WsClient.connect("/app/#{config.key}?protocol=7")
      assert %{"data" => %{"code" => 4101}} = next_frame!(client)
      assert {4101, _} = await_close!(client)
    end

    test "prep_stop drains and returns the state" do
      assert Arc.Application.prep_stop(:state) == :state
      assert Arc.Health.draining?()
    end
  end

  describe "readiness and Postgres" do
    test "goes 503 while Postgres is unreachable and back to 200 after", %{config: config} do
      # Whatever happens, leave the node ready for the tests after this one.
      on_exit(fn ->
        if is_nil(Process.whereis(Arc.Repo)),
          do: Supervisor.restart_child(Arc.Supervisor, Arc.Repo)

        Arc.Health.check_db_now()
      end)

      {client, _} = connect!(config)
      subscribe!(client, "still-here")
      await_event!(client, "pusher_internal:subscription_succeeded")

      :ok = Supervisor.terminate_child(Arc.Supervisor, Arc.Repo)

      try do
        log = capture_log(fn -> refute Arc.Health.check_db_now() end)
        assert log =~ "Postgres is unreachable"
        assert %{status: 503, body: "database unreachable"} = ready()

        # A migration check that cannot reach the database counts as not applied.
        :persistent_term.put({Arc.Health, :migrated}, false)
        refute Arc.Health.migrations_applied?()

        # The data plane does not care.
        {:ok, channel} = Arc.Channels.Channel.parse("still-here")
        Arc.Realtime.publish(config, [channel], "ping", "{}")
        assert %{"event" => "ping"} = await_event!(client, "ping")
      after
        {:ok, _} = Supervisor.restart_child(Arc.Supervisor, Arc.Repo)
      end

      assert Arc.Health.check_db_now()
      assert ready().status == 200
      assert Arc.Health.ready?()
    end

    test "the periodic check runs on its own when given an interval" do
      {:ok, pid} = GenServer.start_link(Arc.Health, db_check_interval: 10)
      Process.sleep(50)
      assert Arc.Health.db_ok?()
      GenServer.stop(pid)
    end

    test "the migration check is re-run once and then remembered" do
      :persistent_term.put({Arc.Health, :migrated}, false)
      assert Arc.Health.ready?()
      assert :persistent_term.get({Arc.Health, :migrated})
    end

    test "a cold app cache is 503 not ready" do
      ready_key = {Arc.Apps.Cache, :ready}
      :persistent_term.put(ready_key, false)
      on_exit(fn -> :persistent_term.put(ready_key, true) end)
      assert %{status: 503, body: "not ready"} = ready()
    end
  end

  describe "connection attempts per address" do
    test "are limited with 429 and Retry-After before the upgrade", %{config: config} do
      override(:connect_rate_per_minute, 2)
      Arc.RateLimiter.reset({:connect, {127, 0, 0, 1}})
      on_exit(fn -> Arc.RateLimiter.reset({:connect, {127, 0, 0, 1}}) end)

      {_c1, _} = connect!(config)
      {_c2, _} = connect!(config)

      assert {:error, {_reason, 429}} = WsClient.connect("/app/#{config.key}?protocol=7")

      resp =
        Req.get!(@base <> "/app/#{config.key}?protocol=7",
          headers: [{"upgrade", "websocket"}, {"connection", "upgrade"}],
          retry: false
        )

      assert resp.status == 429
      assert [retry] = Req.Response.get_header(resp, "retry-after")
      assert String.to_integer(retry) >= 1
      assert resp.body =~ "Too many connection attempts"
    end
  end

  describe "subscribe attempts per connection" do
    test "are limited with a RateLimited subscription error", %{config: config} do
      override(:subscribe_rate, 2)
      {client, _} = connect!(config)

      subscribe!(client, "a")
      await_event!(client, "pusher_internal:subscription_succeeded")
      subscribe!(client, "b")
      await_event!(client, "pusher_internal:subscription_succeeded")
      subscribe!(client, "c")

      frame = await_event!(client, "pusher:subscription_error")
      assert frame["channel"] == "c"
      assert %{"type" => "RateLimited", "status" => 429, "error" => error} = decode_data(frame)
      assert error =~ "retry after"
    end
  end

  describe "repeated authorisation failures" do
    test "close the connection with 4010", %{config: config} do
      override(:auth_failure_limit, 2)
      {client, _} = connect!(config)

      for _ <- 1..2 do
        subscribe!(client, "private-x", %{auth: "#{config.key}:deadbeef"})
        frame = await_event!(client, "pusher:subscription_error")
        assert %{"status" => 401} = decode_data(frame)
      end

      log =
        capture_log(fn ->
          subscribe!(client, "private-x", %{auth: "#{config.key}:deadbeef"})
          assert %{"data" => %{"code" => 4010}} = await_event!(client, "pusher:error")
          assert {4010, _} = await_close!(client)
        end)

      assert log =~ "repeated auth failures"
    end

    test "a malformed subscribe (400) does not count", %{config: config} do
      override(:auth_failure_limit, 1)
      {client, socket_id} = connect!(config)

      for _ <- 1..3 do
        # Correctly signed, but a presence channel without channel_data is a 400.
        subscribe_auth!(client, config, socket_id, "presence-x")
        frame = await_event!(client, "pusher:subscription_error")
        assert %{"status" => 400} = decode_data(frame)
      end

      # Still open: a public subscribe works.
      subscribe!(client, "open")
      await_event!(client, "pusher_internal:subscription_succeeded")
    end
  end
end
