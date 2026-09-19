defmodule Arc.Metrics.Supervisor do
  @moduledoc "Prometheus exporter, VM pollers, and the dashboard aggregator."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {TelemetryMetricsPrometheus.Core, metrics: Arc.Metrics.metrics(), name: :arc_prometheus},
      {:telemetry_poller,
       name: :arc_vm_poller,
       period: :timer.seconds(5),
       measurements: [
         :memory,
         :total_run_queue_lengths,
         :system_counts,
         {Arc.Metrics, :scheduler_utilization, []}
       ]},
      Arc.Metrics.Aggregator
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
