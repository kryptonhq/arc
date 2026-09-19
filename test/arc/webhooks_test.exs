defmodule Arc.WebhooksTest do
  use Arc.RealtimeCase

  alias Arc.{Apps, Audit, Webhooks}
  alias Arc.Test.WebhookReceiver
  alias Arc.Webhooks.{Delivery, Scheduler}

  setup do
    {receiver, url} = WebhookReceiver.start(self())

    on_exit(fn ->
      # Let debounce timers, batches, and in-flight deliveries finish while the
      # sandbox connection still exists.
      Process.sleep(350)
      Arc.Webhooks.Batcher.flush_all()
      wait_for_tasks()
      Process.exit(receiver, :shutdown)
    end)

    app = app_fixture(%{"client_events_enabled" => true})
    %{app: app, url: url}
  end

  defp endpoint!(app, url, events) do
    {:ok, endpoint} = Webhooks.create_endpoint(app, %{"url" => url, "events" => events})
    endpoint
  end

  defp await_webhook(timeout \\ 2_000) do
    receive do
      {:webhook, request} -> request
    after
      timeout -> raise "no webhook received"
    end
  end

  defp refute_webhook(timeout) do
    receive do
      {:webhook, request} -> raise "unexpected webhook: #{request.body}"
    after
      timeout -> :ok
    end
  end

  describe "endpoints" do
    test "CRUD is validated, audited, and reflected in the app config", %{app: app, url: url} do
      assert {:error, changeset} =
               Webhooks.create_endpoint(app, %{"url" => "ftp://x", "events" => ["nope"]})

      assert errors_on(changeset).url != []
      assert errors_on(changeset).events != []
      assert {:error, _} = Webhooks.create_endpoint(app, %{"url" => url, "events" => []})

      endpoint = endpoint!(app, url, ["channel_occupied"])
      assert [%{url: ^url}] = Apps.get_config(app.id).webhooks
      assert [_] = Webhooks.list_endpoints(app.id)
      assert Webhooks.get_endpoint!(app.id, endpoint.id).id == endpoint.id
      assert Webhooks.change_endpoint().valid? == false

      {:ok, endpoint} = Webhooks.update_endpoint(endpoint, %{"active" => false})
      assert Apps.get_config(app.id).webhooks == []

      {:ok, _} = Webhooks.delete_endpoint(endpoint)
      assert Webhooks.list_endpoints(app.id) == []

      actions = Audit.list(app_id: app.id) |> Enum.map(& &1.action)

      assert "webhook.created" in actions and "webhook.updated" in actions and
               "webhook.deleted" in actions
    end

    test "event types" do
      assert "channel_occupied" in Webhooks.event_types()
      assert length(Webhooks.event_types()) == 6
    end
  end

  describe "delivery" do
    test "occupied and vacated are signed with the app secret", %{app: app, url: url} do
      endpoint!(app, url, ["channel_occupied", "channel_vacated"])
      config = Apps.get_config(app.id)

      {client, _} = connect!(config)
      subscribe!(client, "room")
      next_frame!(client)

      request = await_webhook()
      assert request.headers["x-pusher-key"] == config.key

      assert request.headers["x-pusher-signature"] ==
               Arc.Crypto.hmac_sha256_hex(config.secret, request.body)

      assert request.headers["content-type"] == "application/json"

      body = Jason.decode!(request.body)
      assert is_integer(body["time_ms"])
      assert body["events"] == [%{"name" => "channel_occupied", "channel" => "room"}]

      WsClient.close(client)
      request = await_webhook()

      assert Jason.decode!(request.body)["events"] == [
               %{"name" => "channel_vacated", "channel" => "room"}
             ]

      eventually(fn ->
        Enum.all?(Webhooks.list_deliveries(app.id), &(&1.status == "delivered"))
      end)

      assert length(Webhooks.list_deliveries(app.id)) == 2
    end

    test "an endpoint secret adds a second signature", %{app: app, url: url} do
      {:ok, _} =
        Webhooks.create_endpoint(app, %{
          "url" => url,
          "events" => ["cache_miss"],
          "secret" => "ep-secret"
        })

      {client, _} = connect!(Apps.get_config(app.id))
      subscribe!(client, "cache-x")

      request = await_webhook()

      assert request.headers["x-arc-signature"] ==
               Arc.Crypto.hmac_sha256_hex("ep-secret", request.body)

      assert [%{"name" => "cache_miss", "channel" => "cache-x"}] =
               Jason.decode!(request.body)["events"]
    end

    test "a flapping client produces no occupied/vacated pair", %{app: app, url: url} do
      endpoint!(app, url, ["channel_occupied", "channel_vacated"])
      config = Apps.get_config(app.id)

      {first, _} = connect!(config)
      subscribe!(first, "flap")
      next_frame!(first)

      assert %{"events" => [%{"name" => "channel_occupied"}]} =
               Jason.decode!(await_webhook().body)

      # Leave and come back inside the debounce window.
      WsClient.close(first)
      eventually(fn -> Arc.Realtime.Occupancy.subscription_count(config.id, "flap") == 0 end)
      {second, _} = connect!(config)
      subscribe!(second, "flap")
      next_frame!(second)

      refute_webhook(500)
    end

    test "member_added and member_removed are debounced per user id", %{app: app, url: url} do
      endpoint!(app, url, ["member_added", "member_removed"])
      config = Apps.get_config(app.id)

      join = fn user ->
        {client, socket_id} = connect!(config)
        subscribe_auth!(client, config, socket_id, "presence-w", Jason.encode!(%{user_id: user}))
        await_event!(client, "pusher_internal:subscription_succeeded")
        client
      end

      a = join.("alice")

      assert %{
               "events" => [
                 %{"name" => "member_added", "channel" => "presence-w", "user_id" => "alice"}
               ]
             } =
               Jason.decode!(await_webhook().body)

      # A second connection for the same user is not a new member.
      a2 = join.("alice")
      refute_webhook(300)

      WsClient.close(a)
      WsClient.close(a2)

      assert %{"events" => [%{"name" => "member_removed", "user_id" => "alice"}]} =
               Jason.decode!(await_webhook(3_000).body)
    end

    test "client events are delivered only to endpoints that opt in", %{app: app, url: url} do
      endpoint!(app, url, ["client_event"])
      config = Apps.get_config(app.id)

      {a, a_id} = connect!(config)
      subscribe_auth!(a, config, a_id, "private-c")
      await_event!(a, "pusher_internal:subscription_succeeded")

      WsClient.send_json(a, %{event: "client-hello", channel: "private-c", data: %{"x" => 1}})

      assert %{
               "events" => [
                 %{
                   "name" => "client_event",
                   "channel" => "private-c",
                   "event" => "client-hello",
                   "data" => ~s({"x":1}),
                   "socket_id" => ^a_id
                 }
               ]
             } = Jason.decode!(await_webhook().body)
    end

    test "events inside the batch window share one request", %{app: app, url: url} do
      endpoint!(app, url, ["cache_miss"])
      config = Apps.get_config(app.id)
      {client, _} = connect!(config)
      for c <- ["cache-1", "cache-2", "cache-3"], do: subscribe!(client, c)

      events = Jason.decode!(await_webhook().body)["events"]
      assert length(events) == 3
    end

    test "5xx responses are retried with backoff, then marked failed", %{app: app, url: url} do
      WebhookReceiver.set_status(self(), 500)
      endpoint!(app, url, ["cache_miss"])
      {client, _} = connect!(Apps.get_config(app.id))
      subscribe!(client, "cache-r")

      await_webhook()
      [delivery] = eventually(fn -> match_deliveries(app.id, "pending") end)
      assert delivery.attempts == 1
      assert delivery.last_error =~ "500"

      # Retries follow the configured schedule; make them due now and poll.
      for attempt <- 2..5 do
        make_due(delivery.id)
        assert Scheduler.poll_now() == 1
        await_webhook()
        eventually(fn -> Arc.Repo.get!(Delivery, delivery.id).attempts == attempt end)
      end

      make_due(delivery.id)
      Scheduler.poll_now()
      await_webhook()
      eventually(fn -> Arc.Repo.get!(Delivery, delivery.id).status == "failed" end)
      assert Arc.Repo.get!(Delivery, delivery.id).attempts == 6
    end

    test "4xx responses are not retried", %{app: app, url: url} do
      WebhookReceiver.set_status(self(), 404)
      endpoint!(app, url, ["cache_miss"])
      {client, _} = connect!(Apps.get_config(app.id))
      subscribe!(client, "cache-4")

      await_webhook()
      [delivery] = eventually(fn -> match_deliveries(app.id, "failed") end)
      assert delivery.attempts == 1
      assert delivery.last_error =~ "404"
    end

    test "timeouts are retried", %{app: app, url: url} do
      original = Application.fetch_env!(:arc, Arc.Webhooks)
      Application.put_env(:arc, Arc.Webhooks, Keyword.put(original, :request_timeout, 100))
      on_exit(fn -> Application.put_env(:arc, Arc.Webhooks, original) end)

      WebhookReceiver.set_status(self(), :timeout)
      endpoint!(app, url, ["cache_miss"])
      {client, _} = connect!(Apps.get_config(app.id))
      subscribe!(client, "cache-t")

      [delivery] = eventually(fn -> match_deliveries(app.id, "pending") end, 3_000)
      assert delivery.last_error =~ "timeout"
    end

    test "deliveries for removed endpoints fail cleanly", %{app: app, url: url} do
      endpoint = endpoint!(app, url, ["cache_miss"])

      delivery =
        Arc.Repo.insert!(%Delivery{
          app_id: app.id,
          endpoint_id: endpoint.id,
          payload: %{},
          status: "pending",
          next_attempt_at: DateTime.utc_now()
        })

      {:ok, _} = Webhooks.update_endpoint(endpoint, %{"active" => false})
      Arc.Webhooks.Deliverer.attempt(delivery)
      assert Arc.Repo.get!(Delivery, delivery.id).status == "failed"
    end

    test "expired in-flight leases are picked up again", %{app: app, url: url} do
      endpoint = endpoint!(app, url, ["cache_miss"])
      past = DateTime.add(DateTime.utc_now(), -5, :second)

      Arc.Repo.insert!(%Delivery{
        app_id: app.id,
        endpoint_id: endpoint.id,
        payload: %{"events" => []},
        status: "in_flight",
        next_attempt_at: past
      })

      assert Scheduler.poll_now() == 1
      await_webhook()
    end

    test "apps without interested endpoints produce no deliveries", %{app: app, url: url} do
      endpoint!(app, url, ["member_added"])
      {client, _} = connect!(Apps.get_config(app.id))
      subscribe!(client, "cache-none")
      refute_webhook(300)
      assert Webhooks.list_deliveries(app.id) == []
    end

    test "the batcher flushes on demand and prunes nothing recent", %{app: app, url: url} do
      endpoint!(app, url, ["cache_miss"])
      Arc.Webhooks.Batcher.add(app.id, %{name: "cache_miss", channel: "x"})
      Arc.Webhooks.Batcher.flush_all()
      await_webhook()

      send(Scheduler, :prune)
      send(Scheduler, :depth)
      _ = :sys.get_state(Scheduler)
      eventually(fn -> length(Webhooks.list_deliveries(app.id)) == 1 end)
      assert Webhooks.queue_depth() >= 0
    end
  end

  defp match_deliveries(app_id, status) do
    case Webhooks.list_deliveries(app_id) do
      [%{status: ^status}] = list -> list
      _ -> nil
    end
  end

  defp make_due(id) do
    import Ecto.Query
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    Arc.Repo.update_all(from(d in Delivery, where: d.id == ^id and d.status == "pending"),
      set: [next_attempt_at: past]
    )

    eventually(fn -> Arc.Repo.get!(Delivery, id).status == "pending" end)
  end

  defp wait_for_tasks(attempts \\ 100) do
    if Task.Supervisor.children(Arc.Webhooks.TaskSupervisor) != [] and attempts > 0 do
      Process.sleep(20)
      wait_for_tasks(attempts - 1)
    end
  end

  defp errors_on(changeset), do: Arc.DataCase.errors_on(changeset)
end
