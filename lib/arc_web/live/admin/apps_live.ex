defmodule ArcWeb.Admin.AppsLive do
  @moduledoc "Every app, with what each one is carrying right now."
  use ArcWeb, :live_view

  import ArcWeb.AdminComponents

  alias Arc.Metrics.Aggregator

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arc.PubSub, Aggregator.topic())

    {:ok,
     socket
     |> assign(:page_title, "Apps")
     |> assign(:apps, Arc.Apps.list_apps())
     |> assign(:history, Aggregator.history())
     |> assign(:stats, Aggregator.snapshot())}
  end

  @impl true
  def handle_info({:arc_stats, stats}, socket) do
    {:noreply, assign(socket, stats: stats, apps: Arc.Apps.list_apps())}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :rail_stats, Map.put(assigns.stats, :history, assigns.history))

    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps} stats={@rail_stats}>
      <.page_header title="Apps" subtitle="Each app has its own credentials, channels, and limits.">
        <:actions>
          <.btn navigate={~p"/admin/apps/new"} variant={:primary} icon="hero-plus-small">
            New app
          </.btn>
        </:actions>
      </.page_header>

      <.page_body>
        <.panel body_class="px-5 py-1">
          <.empty
            :if={@apps == []}
            title="No apps yet"
            body="Create one to get an app id, key, and secret you can paste into a client and a backend."
          >
            <:action>
              <.btn navigate={~p"/admin/apps/new"} variant={:primary}>New app</.btn>
            </:action>
          </.empty>

          <.table :if={@apps != []}>
            <:head>
              <th class="py-2.5 font-medium">Name</th>
              <th class="font-medium">Key</th>
              <th class="font-medium">Client events</th>
              <th class="font-medium">Connections</th>
              <th class="text-right font-medium">Subscriptions</th>
            </:head>
            <tr :for={app <- @apps} id={"app-#{app.id}"} class="group">
              <td class="py-2.5">
                <.link
                  navigate={~p"/admin/apps/#{app.id}"}
                  class="font-medium text-ink-900 group-hover:text-signal-600"
                >
                  {app.name}
                </.link>
                <span class="ml-2 tabular text-xs text-ink-400">#{app.id}</span>
                <.pill :if={!app.enabled} kind={:bad} class="ml-2">disabled</.pill>
              </td>
              <td class="font-mono text-xs text-ink-500">{app.key}</td>
              <td class="text-ink-500">{if app.client_events_enabled, do: "on", else: "off"}</td>
              <td id={"app-#{app.id}-connections"} class="tabular text-live-700">
                {fmt(get_in(@stats, [:apps, app.id, :connections]) || 0)}
              </td>
              <td class="text-right tabular text-ink-500">
                {fmt(get_in(@stats, [:apps, app.id, :subscriptions]) || 0)}
              </td>
            </tr>
          </.table>
        </.panel>
      </.page_body>
    </Layouts.app>
    """
  end
end
