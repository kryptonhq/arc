defmodule ArcWeb.HealthMetricsTest do
  use ArcWeb.ConnCase, async: false

  test "GET /health/live", %{conn: conn} do
    assert conn |> get("/health/live") |> text_response(200) == "ok"
  end

  test "GET /health/ready once the cache is warm and migrations ran", %{conn: conn} do
    assert conn |> get("/health/ready") |> text_response(200) == "ready"
  end

  test "GET /metrics exposes every Arc metric without high-cardinality labels", %{conn: conn} do
    emit_one_of_each()
    body = conn |> get("/metrics") |> response(200)

    for name <-
          ~w(arc_connections_active arc_connections_total arc_connection_duration_seconds
                   arc_channels_occupied arc_subscriptions_active arc_messages_sent_total
                   arc_messages_received_total arc_broadcast_duration_seconds arc_api_requests_total
                   arc_api_request_duration_seconds arc_auth_failures_total arc_webhook_deliveries_total
                   arc_webhook_queue_depth arc_presence_members arc_rate_limit_hits_total
                   vm_memory_total vm_total_run_queue_lengths_total vm_system_counts_process_count) do
      assert body =~ name, "missing #{name}"
    end

    labels =
      Regex.scan(~r/(\w+)="/, body) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq() |> Enum.sort()

    for forbidden <- ~w(channel channel_name socket_id user_id), do: refute(forbidden in labels)
  end

  defp emit_one_of_each do
    app = %{app_id: 1}

    :telemetry.execute(
      [:arc, :stats, :app],
      %{connections: 1, subscriptions: 1, presence_members: 1},
      %{app_id: 1, node: "n"}
    )

    :telemetry.execute([:arc, :connection, :open], %{count: 1}, app)
    :telemetry.execute([:arc, :connection, :close], %{duration: 1000}, app)
    :telemetry.execute([:arc, :stats, :channels], %{count: 1}, %{app_id: 1, type: "public"})
    :telemetry.execute([:arc, :message, :sent], %{count: 1}, %{app_id: 1, source: "api"})
    :telemetry.execute([:arc, :message, :received], %{count: 1}, app)
    :telemetry.execute([:arc, :broadcast, :stop], %{duration: 1000}, app)

    :telemetry.execute([:arc, :api, :request], %{duration: 1000}, %{
      app_id: 1,
      endpoint: "events",
      status: 200
    })

    :telemetry.execute([:arc, :auth, :failure], %{count: 1}, %{app_id: 1, reason: "x"})
    :telemetry.execute([:arc, :webhook, :delivery], %{count: 1}, %{status: "delivered"})
    :telemetry.execute([:arc, :webhook, :queue], %{depth: 0}, %{})
    :telemetry.execute([:arc, :rate_limit, :hit], %{count: 1}, %{app_id: 1, kind: "api"})
    :telemetry.execute([:vm, :memory], %{total: 1}, %{})
    :telemetry.execute([:vm, :total_run_queue_lengths], %{total: 0, cpu: 0, io: 0}, %{})
    :telemetry.execute([:vm, :system_counts], %{process_count: 1, port_count: 1}, %{})
  end

  test "GET /metrics requires the bearer token when configured", %{conn: conn} do
    Application.put_env(:arc, :metrics_auth_token, "s3cret")
    on_exit(fn -> Application.delete_env(:arc, :metrics_auth_token) end)

    assert conn |> get("/metrics") |> response(401)

    assert build_conn()
           |> put_req_header("authorization", "Bearer wrong")
           |> get("/metrics")
           |> response(401)

    assert build_conn()
           |> put_req_header("authorization", "Bearer s3cret")
           |> get("/metrics")
           |> response(200)
  end
end
