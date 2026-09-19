defmodule ArcWeb.Admin.OverviewLive do
  @moduledoc "Cluster overview. Numbers arrive from the metrics aggregator once a second."
  use ArcWeb, :live_view

  import ArcWeb.AdminComponents

  alias Arc.Metrics.Aggregator

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arc.PubSub, Aggregator.topic())

    {:ok,
     socket
     |> assign(:page_title, "Overview")
     |> assign(:app_count, length(Arc.Apps.Cache.ids()))
     |> assign(:stats, Aggregator.snapshot())}
  end

  @impl true
  def handle_info({:arc_stats, stats}, socket) do
    {:noreply, assign(socket, stats: stats, app_count: length(Arc.Apps.Cache.ids()))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:overview}>
      <.page_header title="Overview" subtitle="Live across every node in the cluster." />

      <dl class="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <.stat id="stat-connections" label="Connections" value={fmt(@stats.connections)} />
        <.stat id="stat-mps" label="Messages / second" value={fmt(@stats.messages_per_second)} />
        <.stat id="stat-apps" label="Apps" value={fmt(@app_count)} />
        <.stat id="stat-nodes" label="Nodes" value={fmt(length(@stats.nodes))} />
      </dl>

      <.card title="Nodes" class="mt-6">
        <p :if={@stats.nodes == []} class="text-sm text-zinc-500">Waiting for the first report…</p>
        <table :if={@stats.nodes != []} class="w-full text-left text-sm">
          <thead class="text-xs uppercase text-zinc-500">
            <tr>
              <th class="py-2">Node</th><th>Connections</th><th>Memory</th><th>Run queue</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-100">
            <tr :for={n <- @stats.nodes}>
              <td class="py-2 font-mono text-xs">{n.name}</td>
              <td class="tabular-nums">{fmt(n.connections)}</td>
              <td class="tabular-nums">{fmt_bytes(n.memory)}</td>
              <td class="tabular-nums">{n.run_queue}</td>
            </tr>
          </tbody>
        </table>
      </.card>
    </Layouts.app>
    """
  end
end
