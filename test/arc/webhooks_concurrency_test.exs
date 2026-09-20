defmodule Arc.WebhooksConcurrencyTest do
  use Arc.DataCase, async: false

  alias Arc.Webhooks
  alias Arc.Webhooks.{Deliverer, Delivery, Scheduler}

  setup do
    {:ok, app, _secret} = Arc.Apps.create_app(%{"name" => "hooks"})

    {:ok, endpoint} =
      Webhooks.create_endpoint(app, %{
        "url" => "https://example.com/h",
        "events" => ["channel_occupied"]
      })

    %{app: app, endpoint: endpoint}
  end

  defp fill_slots do
    limit = Application.fetch_env!(:arc, Arc.Webhooks) |> Keyword.fetch!(:max_concurrency)

    tasks =
      for _ <- 1..limit do
        {:ok, pid} =
          Task.Supervisor.start_child(Arc.Webhooks.TaskSupervisor, fn ->
            Process.sleep(:infinity)
          end)

        pid
      end

    on_exit(fn ->
      Enum.each(tasks, &Task.Supervisor.terminate_child(Arc.Webhooks.TaskSupervisor, &1))
    end)

    tasks
  end

  test "beyond max_concurrency new deliveries wait as pending and the scheduler backs off",
       %{app: app, endpoint: endpoint} do
    tasks = fill_slots()
    assert Deliverer.free_slots() == 0

    assert {:ok, :queued} = Deliverer.enqueue(app.id, endpoint.id, %{events: []})
    assert [%Delivery{status: "pending", attempts: 0}] = Repo.all(Delivery)
    assert Scheduler.poll_now() == 0

    # A row already claimed by a scheduler on this node is released again.
    delivery = Repo.one!(Delivery) |> Ecto.Changeset.change(status: "in_flight") |> Repo.update!()
    assert {:ok, :queued} = Deliverer.start(delivery)
    assert Repo.reload!(delivery).status == "pending"

    Enum.each(tasks, &Task.Supervisor.terminate_child(Arc.Webhooks.TaskSupervisor, &1))
    assert Deliverer.free_slots() > 0
  end

  test "retry_failed re-queues an endpoint's failed deliveries with a fresh budget",
       %{app: app, endpoint: endpoint} do
    for status <- ["failed", "failed", "delivered"] do
      Repo.insert!(%Delivery{
        app_id: app.id,
        endpoint_id: endpoint.id,
        payload: %{},
        status: status,
        attempts: 7,
        last_error: "boom",
        next_attempt_at: DateTime.utc_now()
      })
    end

    assert Webhooks.retry_failed(app.id, endpoint.id) == 2
    assert Webhooks.retry_failed(app.id, endpoint.id) == 0

    statuses = Repo.all(Delivery) |> Enum.map(& &1.status) |> Enum.sort()
    assert statuses == ["delivered", "pending", "pending"]
    assert Enum.all?(Repo.all(Delivery), &(&1.status == "delivered" or &1.attempts == 0))
  end
end
