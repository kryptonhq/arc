defmodule ArcWeb.Admin.AppsLive do
  @moduledoc "App list with live connection counts."
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
     |> assign(:stats, Aggregator.snapshot())}
  end

  @impl true
  def handle_info({:arc_stats, stats}, socket), do: {:noreply, assign(socket, :stats, stats)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header title="Apps">
        <:actions>
          <.btn href={~p"/admin/apps/new"} variant={:primary}>New app</.btn>
        </:actions>
      </.page_header>

      <.card>
        <p :if={@apps == []} class="text-sm text-zinc-500">
          No apps yet. Create one to get credentials.
        </p>
        <table :if={@apps != []} class="w-full text-left text-sm">
          <thead class="text-xs uppercase text-zinc-500">
            <tr>
              <th class="py-2">Name</th><th>ID</th><th>Key</th><th>Status</th><th class="text-right">
                Connections
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-100">
            <tr :for={app <- @apps} id={"app-#{app.id}"} class="hover:bg-zinc-50">
              <td class="py-2">
                <.link
                  navigate={~p"/admin/apps/#{app.id}"}
                  class="font-medium text-indigo-600 hover:text-indigo-500"
                >{app.name}</.link>
              </td>
              <td class="tabular-nums">{app.id}</td>
              <td class="font-mono text-xs">{app.key}</td>
              <td>
                <.badge :if={app.enabled} kind={:good}>enabled</.badge>
                <.badge :if={!app.enabled} kind={:bad}>disabled</.badge>
              </td>
              <td class="text-right tabular-nums" id={"app-#{app.id}-connections"}>
                {fmt(connections(@stats, app.id))}
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </Layouts.app>
    """
  end

  defp connections(stats, app_id), do: get_in(stats, [:apps, app_id, :connections]) || 0
end
