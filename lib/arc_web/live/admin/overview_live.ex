defmodule ArcWeb.Admin.OverviewLive do
  @moduledoc """
  What the cluster is doing right now. Numbers arrive from the metrics aggregator
  once a second; the stream is the aggregator's own samples, not an animation.
  """
  use ArcWeb, :live_view

  import ArcWeb.AdminComponents

  alias Arc.Metrics.Aggregator

  @history 120

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arc.PubSub, Aggregator.topic())

    {:ok,
     socket
     |> assign(:page_title, "Overview")
     |> assign(:apps, Arc.Apps.list_apps())
     |> assign(:activity, Arc.Audit.list(limit: 6))
     |> assign(:history, Aggregator.history())
     |> assign(:stats, Aggregator.snapshot())}
  end

  @impl true
  def handle_info({:arc_stats, stats}, socket) do
    history =
      (socket.assigns.history ++
         [
           %{
             at: System.system_time(:second),
             connections: stats.connections,
             messages_per_second: stats.messages_per_second
           }
         ])
      |> Enum.take(-@history)

    {:noreply, assign(socket, stats: stats, history: history, apps: Arc.Apps.list_apps())}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :rail_stats, Map.put(assigns.stats, :history, assigns.history))

    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:overview} stats={@rail_stats}>
      <.page_header title="Overview" subtitle="Every node in this cluster, sampled once a second.">
        <:status>
          <.pill kind={:live}>
            <span class="live-dot size-1.5 rounded-full bg-live-600"></span> live
          </.pill>
        </:status>
        <:actions>
          <.btn navigate={~p"/admin/apps/new"} variant={:primary} icon="hero-plus-small">
            New app
          </.btn>
        </:actions>
      </.page_header>

      <.page_body>
        <section class="rounded-[var(--radius-panel)] border border-rule bg-surface">
          <div class="flex flex-wrap items-end justify-between gap-6 px-5 pt-5">
            <div class="readout">
              <p class="text-xs text-ink-500">Connections</p>
              <p
                id="stat-connections"
                class="mt-1 text-[2.75rem] font-semibold leading-none tracking-tight text-ink-900"
              >
                {fmt(@stats.connections)}
              </p>
            </div>
            <dl class="readout flex gap-8 pb-1 text-right">
              <div>
                <dt class="text-xs text-ink-500">Messages / second</dt>
                <dd id="stat-mps" class="mt-1 text-xl font-semibold tracking-tight text-live-700">
                  {fmt(@stats.messages_per_second)}
                </dd>
              </div>
              <div>
                <dt class="text-xs text-ink-500">Apps</dt>
                <dd id="stat-apps" class="mt-1 text-xl font-semibold tracking-tight text-ink-900">
                  {fmt(length(@apps))}
                </dd>
              </div>
              <div>
                <dt class="text-xs text-ink-500">Nodes</dt>
                <dd id="stat-nodes" class="mt-1 text-xl font-semibold tracking-tight text-ink-900">
                  {fmt(length(@stats.nodes))}
                </dd>
              </div>
            </dl>
          </div>

          <.sparkline
            points={Enum.map(@history, & &1.connections)}
            class="mt-4 h-20 w-full text-live-600 sm:h-28"
          />
          <p class="border-t border-rule px-5 py-2 text-xs text-ink-400">
            {window_label(@history)}
          </p>
        </section>

        <div class="mt-6 grid gap-6 [&>*]:min-w-0 lg:grid-cols-2">
          <.panel title="Nodes" note="Connections are counted where they are held.">
            <.empty
              :if={@stats.nodes == []}
              title="No reports yet"
              body="Nodes publish their numbers once a second. If this stays empty, check that the metrics aggregator is running."
            />
            <.table :if={@stats.nodes != []}>
              <:head>
                <th class="py-2 font-medium">Node</th>
                <th class="font-medium">Connections</th>
                <th class="font-medium">Memory</th>
                <th class="text-right font-medium">Run queue</th>
              </:head>
              <tr :for={node <- @stats.nodes}>
                <td class="py-2 font-mono text-xs text-ink-800">{node.name}</td>
                <td class="tabular">{fmt(node.connections)}</td>
                <td class="tabular text-ink-500">{fmt_bytes(node.memory)}</td>
                <td class={[
                  "text-right tabular",
                  node.run_queue > 10 && "text-amber-ink",
                  node.run_queue <= 10 && "text-ink-500"
                ]}>
                  {node.run_queue}
                </td>
              </tr>
            </.table>
          </.panel>

          <.panel title="Apps" note="Live connection counts across the cluster.">
            <:actions>
              <.btn navigate={~p"/admin/apps"} variant={:quiet}>All apps</.btn>
            </:actions>
            <.empty
              :if={@apps == []}
              title="No apps yet"
              body="An app is a set of credentials and its own set of channels."
            >
              <:action>
                <.btn navigate={~p"/admin/apps/new"} variant={:primary}>New app</.btn>
              </:action>
            </.empty>
            <ul :if={@apps != []} class="divide-y divide-rule">
              <li :for={app <- @apps} class="flex items-center justify-between gap-3 py-2.5">
                <.link
                  navigate={~p"/admin/apps/#{app.id}"}
                  class="min-w-0 truncate text-sm font-medium text-ink-900 hover:text-signal-600"
                >
                  {app.name}
                </.link>
                <span class="flex items-center gap-3">
                  <.pill :if={!app.enabled} kind={:bad}>disabled</.pill>
                  <span class="tabular text-sm text-ink-500">
                    {fmt(get_in(@stats, [:apps, app.id, :connections]) || 0)}
                  </span>
                </span>
              </li>
            </ul>
          </.panel>
        </div>

        <.panel class="mt-6" title="Recent changes" note="From the audit log.">
          <:actions>
            <.btn href={~p"/admin/audit"} variant={:quiet}>Audit log</.btn>
          </:actions>
          <.empty
            :if={@activity == []}
            title="Nothing has changed yet"
            body="Creating an app or editing a webhook writes a line here."
          />
          <ul :if={@activity != []} class="divide-y divide-rule">
            <li
              :for={entry <- @activity}
              class="flex items-baseline justify-between gap-4 py-2 text-sm"
            >
              <span class="min-w-0 truncate">
                <span class="text-ink-500">{(entry.admin_user && entry.admin_user.email) || "system"}</span>
                <code class="ml-1.5 font-mono text-xs text-ink-800">{entry.action}</code>
                <span :if={entry.app_id} class="ml-1.5 text-ink-400">app {entry.app_id}</span>
              </span>
              <span class="shrink-0 text-xs text-ink-400" title={fmt_time(entry.inserted_at)}>
                {fmt_ago(entry.inserted_at)}
              </span>
            </li>
          </ul>
        </.panel>
      </.page_body>
    </Layouts.app>
    """
  end

  defp window_label([]), do: "Waiting for the first sample."
  defp window_label([_]), do: "Waiting for the first sample."
  defp window_label(history), do: "Last #{length(history)} seconds of connections."
end
