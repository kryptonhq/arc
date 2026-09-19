defmodule ArcWeb.Admin.AppLive do
  @moduledoc """
  One app: credentials (key only), settings summary, live connection count, the
  channel list, and recent webhook deliveries. Channel lists are read on demand,
  when the page loads or the admin asks for a refresh, never on a timer.
  """
  use ArcWeb, :live_view

  import ArcWeb.AdminComponents

  alias Arc.Metrics.Aggregator

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    app = Arc.Apps.get_app!(id)
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arc.PubSub, Aggregator.topic())

    {:ok,
     socket
     |> assign(:page_title, app.name)
     |> assign(:app, app)
     |> assign(:stats, Aggregator.snapshot())
     |> assign(:deliveries, Arc.Webhooks.list_deliveries(app.id, limit: 10))
     |> load_channels()}
  end

  @impl true
  def handle_event("refresh_channels", _params, socket) do
    {:noreply,
     socket
     |> load_channels()
     |> assign(:deliveries, Arc.Webhooks.list_deliveries(socket.assigns.app.id, limit: 10))}
  end

  @impl true
  def handle_info({:arc_stats, stats}, socket), do: {:noreply, assign(socket, :stats, stats)}

  defp load_channels(socket) do
    channels =
      socket.assigns.app.id
      |> Arc.Realtime.occupied_channels()
      |> Enum.sort_by(fn {name, count} -> {-count, name} end)
      |> Enum.take(200)

    assign(socket, :channels, channels)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header title={@app.name} subtitle={"App #{@app.id}"}>
        <:actions>
          <.btn href={~p"/admin/apps/#{@app.id}/webhooks"}>Webhooks</.btn>
          <.btn href={~p"/admin/apps/#{@app.id}/edit"}>Settings</.btn>
        </:actions>
      </.page_header>

      <dl class="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <.stat
          id="app-connections"
          label="Connections"
          value={fmt(get_in(@stats, [:apps, @app.id, :connections]) || 0)}
        />
        <.stat
          id="app-subscriptions"
          label="Subscriptions"
          value={fmt(get_in(@stats, [:apps, @app.id, :subscriptions]) || 0)}
        />
        <.stat label="Occupied channels" value={fmt(length(@channels))} />
        <.stat label="Status" value={if @app.enabled, do: "Enabled", else: "Disabled"} />
      </dl>

      <div class="mt-6 grid gap-6 lg:grid-cols-2">
        <.card title="Credentials">
          <dl>
            <.credential id="cred-app-id" label="App ID" value={to_string(@app.id)} />
            <.credential id="cred-key" label="Key" value={@app.key} />
            <.credential id="cred-host" label="Host" value={ArcWeb.Snippets.public_endpoint().host} />
            <.credential
              id="cred-port"
              label="Port"
              value={to_string(ArcWeb.Snippets.public_endpoint().port)}
            />
          </dl>
          <p class="mt-3 text-xs text-zinc-500">
            The secret was shown once when it was created. Rotating issues a new one and invalidates the old one immediately.
          </p>
          <div class="mt-4 flex flex-wrap gap-2">
            <.btn
              href={~p"/admin/apps/#{@app.id}/rotate"}
              method="post"
              data-confirm="Rotate the secret? The current secret stops working immediately."
            >
              Rotate secret
            </.btn>
            <.btn
              :if={is_nil(@app.encryption_master_key)}
              href={~p"/admin/apps/#{@app.id}/encryption_key?action=generate"}
              method="post"
            >
              Generate encryption key
            </.btn>
            <.btn
              :if={@app.encryption_master_key}
              href={~p"/admin/apps/#{@app.id}/encryption_key?action=generate"}
              method="post"
              data-confirm="Replace the encryption master key? Clients using the old key will stop decrypting."
            >
              Replace encryption key
            </.btn>
            <.btn
              :if={@app.encryption_master_key}
              href={~p"/admin/apps/#{@app.id}/encryption_key?action=remove"}
              method="post"
              data-confirm="Remove the encryption master key? Encrypted channels stop accepting events."
            >
              Remove encryption key
            </.btn>
          </div>
        </.card>

        <.card title="Settings">
          <dl class="text-sm">
            <.setting
              label="Client events"
              value={if @app.client_events_enabled, do: "Allowed", else: "Off"}
            />
            <.setting
              label="Connection limit"
              value={fmt(@app.max_connections) |> then(&if(&1 == "—", do: "Unlimited", else: &1))}
            />
            <.setting
              label="Presence ceiling"
              value={if @app.enable_presence_limits, do: fmt(@app.max_presence_members), else: "Off"}
            />
            <.setting label="Payload limit" value={"#{fmt(@app.max_payload_bytes)} bytes"} />
            <.setting
              label="subscription_count queries"
              value={if @app.subscription_count_enabled, do: "Allowed", else: "Off"}
            />
            <.setting
              label="Encrypted channels"
              value={if @app.encryption_master_key, do: "Key configured", else: "No key"}
            />
          </dl>
          <div class="mt-4 border-t border-zinc-100 pt-4">
            <.btn
              href={~p"/admin/apps/#{@app.id}"}
              method="delete"
              variant={:danger}
              data-confirm={"Delete #{@app.name}? Every connection is closed and the credentials stop working."}
            >
              Delete app
            </.btn>
          </div>
        </.card>
      </div>

      <.card title="Channels" class="mt-6">
        <:actions>
          <.btn phx-click="refresh_channels" type="button">Refresh</.btn>
        </:actions>
        <p :if={@channels == []} class="text-sm text-zinc-500">No occupied channels.</p>
        <table :if={@channels != []} class="w-full text-left text-sm">
          <thead class="text-xs uppercase text-zinc-500">
            <tr>
              <th class="py-2">Channel</th><th class="text-right">Subscriptions</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-100">
            <tr :for={{name, count} <- @channels}>
              <td class="py-1.5 font-mono text-xs">{name}</td>
              <td class="text-right tabular-nums">{fmt(count)}</td>
            </tr>
          </tbody>
        </table>
      </.card>

      <.card title="Recent webhook deliveries" class="mt-6">
        <:actions>
          <.btn href={~p"/admin/apps/#{@app.id}/webhooks"}>All deliveries</.btn>
        </:actions>
        <ArcWeb.Admin.WebhookHTML.deliveries deliveries={@deliveries} />
      </.card>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp setting(assigns) do
    ~H"""
    <div class="flex justify-between border-b border-zinc-100 py-2 last:border-0">
      <dt class="text-zinc-500">{@label}</dt>
      <dd class="font-medium">{@value}</dd>
    </div>
    """
  end
end
