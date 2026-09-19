defmodule Arc.Metrics do
  @moduledoc """
  Metric definitions for the Prometheus exporter.

  The data plane only emits `:telemetry` events; this module decides what is exported.
  No metric is labelled with a channel name, socket id, or user id: those are
  unbounded and would take down a Prometheus server. Per-channel numbers are shown in
  the dashboard, computed on demand.
  """
  import Telemetry.Metrics

  @duration_buckets [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
  @connection_buckets [1, 10, 60, 300, 900, 3600, 14_400, 43_200, 86_400]

  def metrics do
    [
      # Connections
      last_value("arc.connections_active",
        event_name: [:arc, :stats, :app],
        measurement: :connections,
        tags: [:app_id, :node]
      ),
      counter("arc.connections_total", event_name: [:arc, :connection, :open], tags: [:app_id]),
      distribution("arc.connection_duration_seconds",
        event_name: [:arc, :connection, :close],
        measurement: :duration,
        unit: {:millisecond, :second},
        tags: [:app_id],
        reporter_options: [buckets: @connection_buckets]
      ),

      # Channels and subscriptions
      last_value("arc.channels_occupied",
        event_name: [:arc, :stats, :channels],
        measurement: :count,
        tags: [:app_id, :type]
      ),
      last_value("arc.subscriptions_active",
        event_name: [:arc, :stats, :app],
        measurement: :subscriptions,
        tags: [:app_id]
      ),
      last_value("arc.presence_members",
        event_name: [:arc, :stats, :app],
        measurement: :presence_members,
        tags: [:app_id]
      ),

      # Messages
      counter("arc.messages_sent_total",
        event_name: [:arc, :message, :sent],
        tags: [:app_id, :source]
      ),
      counter("arc.messages_received_total",
        event_name: [:arc, :message, :received],
        tags: [:app_id]
      ),
      distribution("arc.broadcast_duration_seconds",
        event_name: [:arc, :broadcast, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:app_id],
        reporter_options: [buckets: @duration_buckets]
      ),

      # HTTP API
      counter("arc.api_requests_total",
        event_name: [:arc, :api, :request],
        tags: [:app_id, :endpoint, :status]
      ),
      distribution("arc.api_request_duration_seconds",
        event_name: [:arc, :api, :request],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:endpoint],
        reporter_options: [buckets: @duration_buckets]
      ),

      # Auth, rate limits, webhooks
      counter("arc.auth_failures_total",
        event_name: [:arc, :auth, :failure],
        tags: [:app_id, :reason]
      ),
      counter("arc.rate_limit_hits_total",
        event_name: [:arc, :rate_limit, :hit],
        tags: [:app_id, :kind]
      ),
      counter("arc.webhook_deliveries_total",
        event_name: [:arc, :webhook, :delivery],
        tags: [:status]
      ),
      last_value("arc.webhook_queue_depth",
        event_name: [:arc, :webhook, :queue],
        measurement: :depth
      ),

      # BEAM
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.memory.processes", unit: :byte),
      last_value("vm.memory.binary", unit: :byte),
      last_value("vm.memory.ets", unit: :byte),
      last_value("vm.memory.atom", unit: :byte),
      last_value("vm.memory.code", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),
      last_value("vm.system_counts.process_count"),
      last_value("vm.system_counts.port_count"),
      last_value("vm.scheduler_utilization.total",
        event_name: [:vm, :scheduler_utilization],
        measurement: :total
      )
    ]
  end

  @doc false
  # Polled by telemetry_poller; `:scheduler.utilization/1` blocks for the sample period.
  def scheduler_utilization do
    case :scheduler.utilization(1) do
      [{:total, total, _} | _] ->
        :telemetry.execute([:vm, :scheduler_utilization], %{total: total}, %{})

      _ ->
        :ok
    end
  end
end
