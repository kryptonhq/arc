defmodule ArcWeb.Admin.AppLive do
  @moduledoc """
  One app: what it is carrying, how clients reach it, what it is allowed to do, and
  what its webhooks have been doing.

  Channel lists are read when the page loads and when the operator asks for them,
  never on a timer: a dashboard left open must not add load to the data plane.
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
     |> assign(:filter, "")
     |> assign(:history, Aggregator.history())
     |> assign(:stats, Aggregator.snapshot())
     |> assign(:deliveries, Arc.Webhooks.list_deliveries(app.id, limit: 6))
     |> load_channels()}
  end

  @impl true
  def handle_event("refresh_channels", _params, socket) do
    {:noreply,
     socket
     |> load_channels()
     |> assign(:deliveries, Arc.Webhooks.list_deliveries(socket.assigns.app.id, limit: 6))
     |> assign(:refreshed_at, DateTime.utc_now())}
  end

  def handle_event("filter_channels", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def handle_info({:arc_stats, stats}, socket), do: {:noreply, assign(socket, :stats, stats)}

  defp load_channels(socket) do
    channels =
      socket.assigns.app.id
      |> Arc.Realtime.occupied_channels()
      |> Enum.sort_by(fn {name, count} -> {-count, name} end)

    socket
    |> assign(:channels, channels)
    |> assign(:refreshed_at, DateTime.utc_now())
  end

  defp visible_channels(channels, ""), do: Enum.take(channels, 100)

  defp visible_channels(channels, filter) do
    channels
    |> Enum.filter(fn {name, _} -> String.contains?(name, filter) end)
    |> Enum.take(100)
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:rail_stats, Map.put(assigns.stats, :history, assigns.history))
      |> assign(:app_stats, get_in(assigns.stats, [:apps, assigns.app.id]) || %{})
      |> assign(:visible, visible_channels(assigns.channels, assigns.filter))

    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps} stats={@rail_stats}>
      <.page_header title={@app.name} breadcrumb={[{"Apps", ~p"/admin/apps"}]}>
        <:status>
          <.pill kind={if @app.enabled, do: :good, else: :bad}>
            {if @app.enabled, do: "enabled", else: "disabled"}
          </.pill>
          <span class="tabular text-xs text-ink-400">app id {@app.id}</span>
        </:status>
        <:actions>
          <.btn href={~p"/admin/apps/#{@app.id}/webhooks"} icon="hero-bolt">Webhooks</.btn>
          <.btn href={~p"/admin/apps/#{@app.id}/edit"} icon="hero-adjustments-horizontal">
            Settings
          </.btn>
        </:actions>
      </.page_header>

      <.page_body>
        <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <.readout
            id="app-connections"
            label="Connections"
            value={fmt(Map.get(@app_stats, :connections, 0))}
            tone={:live}
          />
          <.readout
            id="app-subscriptions"
            label="Subscriptions"
            value={fmt(Map.get(@app_stats, :subscriptions, 0))}
            tone={:live}
          />
          <.readout label="Occupied channels" value={fmt(length(@channels))} />
          <.readout
            label="Presence members"
            value={fmt(Map.get(@app_stats, :presence_members, 0))}
          />
        </div>

        <div class="mt-6 grid gap-6 lg:grid-cols-5">
          <div class="min-w-0 space-y-6 lg:col-span-3">
            <.panel
              title="Channels"
              note="Read on demand, so an open dashboard adds no load to the data plane."
            >
              <:actions>
                <span class="text-xs text-ink-400">{fmt_ago(@refreshed_at)}</span>
                <.btn
                  phx-click="refresh_channels"
                  type="button"
                  variant={:quiet}
                  icon="hero-arrow-path"
                >
                  Refresh
                </.btn>
              </:actions>

              <form :if={@channels != []} phx-change="filter_channels" class="mb-3">
                <input
                  type="text"
                  name="filter"
                  value={@filter}
                  placeholder="Filter by name"
                  autocomplete="off"
                  class="w-full rounded-[var(--radius-control)] border border-rule-strong bg-surface px-3 py-1.5 font-mono text-xs placeholder:font-sans placeholder:text-ink-300 focus:border-signal-600 focus:outline-none focus:ring-1 focus:ring-signal-600"
                />
              </form>

              <.empty
                :if={@channels == []}
                title="No occupied channels"
                body="A channel appears here as soon as a client subscribes to it, and disappears when the last subscriber leaves."
              />
              <.empty
                :if={@channels != [] and @visible == []}
                title="No channel matches that filter"
                body="Filtering is a plain substring match on the channel name."
              />

              <ul :if={@visible != []} class="divide-y divide-rule">
                <li
                  :for={{name, count} <- @visible}
                  class="flex items-center justify-between gap-4 py-1.5"
                >
                  <span class="flex min-w-0 items-center gap-2">
                    <.pill kind={:neutral}>{channel_kind(name)}</.pill>
                    <code class="truncate font-mono text-xs text-ink-800">{name}</code>
                  </span>
                  <span class="tabular shrink-0 text-xs text-ink-500">
                    {fmt(count)} <span class="text-ink-400">subs</span>
                  </span>
                </li>
              </ul>
              <p
                :if={length(@channels) > length(@visible) and @filter == ""}
                class="mt-3 text-xs text-ink-400"
              >
                Showing the 100 busiest of {fmt(length(@channels))} channels.
              </p>
            </.panel>

            <.panel title="Recent webhook deliveries">
              <:actions>
                <.btn href={~p"/admin/apps/#{@app.id}/webhooks"} variant={:quiet}>
                  All deliveries
                </.btn>
              </:actions>
              <ArcWeb.Admin.WebhookHTML.deliveries deliveries={@deliveries} compact />
            </.panel>
          </div>

          <div class="min-w-0 space-y-6 lg:col-span-2">
            <.panel title="Credentials" note="Clients need the key; backends need the secret.">
              <dl>
                <.credential id="cred-app-id" label="App id" value={to_string(@app.id)} />
                <.credential id="cred-key" label="Key" value={@app.key} />
                <.credential
                  id="cred-host"
                  label="Host"
                  value={ArcWeb.Snippets.public_endpoint().host}
                />
                <.credential
                  id="cred-port"
                  label="Port"
                  value={to_string(ArcWeb.Snippets.public_endpoint().port)}
                />
              </dl>

              <div class="mt-4 rounded-[var(--radius-control)] border-l-2 border-amber-line bg-amber-wash px-3 py-2 text-xs text-amber-ink">
                The secret was shown once, when it was issued. Rotating issues a new one and
                stops the old one working everywhere, immediately.
              </div>

              <div class="mt-4 flex flex-wrap gap-2">
                <.btn
                  href={~p"/admin/apps/#{@app.id}/rotate"}
                  method="post"
                  data-confirm="Rotate the secret? Anything still signing with the current secret stops working immediately."
                  icon="hero-arrow-path-rounded-square"
                >
                  Rotate secret
                </.btn>
              </div>
            </.panel>

            <.panel title="Encrypted channels">
              <p :if={@app.encryption_master_key} class="text-sm text-ink-500">
                A master key is configured. Backends encrypt with it before publishing to
                <code class="font-mono text-xs">private-encrypted-</code>
                channels, and Arc never sees the plaintext.
              </p>
              <p :if={!@app.encryption_master_key} class="text-sm text-ink-500">
                No master key. Publishing to <code class="font-mono text-xs">private-encrypted-</code>
                channels is refused until one exists.
              </p>
              <div class="mt-4 flex flex-wrap gap-2">
                <.btn
                  href={~p"/admin/apps/#{@app.id}/encryption_key?action=generate"}
                  method="post"
                  data-confirm={
                    @app.encryption_master_key &&
                      "Replace the master key? Clients holding the old key stop decrypting."
                  }
                >
                  {if @app.encryption_master_key, do: "Replace key", else: "Generate key"}
                </.btn>
                <.btn
                  :if={@app.encryption_master_key}
                  href={~p"/admin/apps/#{@app.id}/encryption_key?action=remove"}
                  method="post"
                  variant={:danger}
                  data-confirm="Remove the master key? Encrypted channels stop accepting events."
                >
                  Remove key
                </.btn>
              </div>
            </.panel>

            <.panel title="Limits">
              <dl class="text-sm">
                <.setting label="Client events" value={on_off(@app.client_events_enabled)} />
                <.setting
                  label="Connections"
                  value={if @app.max_connections, do: fmt(@app.max_connections), else: "unlimited"}
                />
                <.setting
                  label="Presence members"
                  value={
                    if @app.enable_presence_limits,
                      do: "#{fmt(@app.max_presence_members)} per channel",
                      else: "unlimited"
                  }
                />
                <.setting label="Event payload" value={"#{fmt(@app.max_payload_bytes)} bytes"} />
                <.setting
                  label="subscription_count queries"
                  value={on_off(@app.subscription_count_enabled)}
                />
              </dl>
              <div class="mt-4 border-t border-rule pt-4">
                <.btn
                  href={~p"/admin/apps/#{@app.id}"}
                  method="delete"
                  variant={:danger}
                  icon="hero-trash"
                  data-confirm={"Delete #{@app.name}? Every connection closes and the credentials stop working."}
                >
                  Delete app
                </.btn>
              </div>
            </.panel>
          </div>
        </div>
      </.page_body>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp setting(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-4 border-b border-rule py-2 last:border-0">
      <dt class="text-ink-500">{@label}</dt>
      <dd class="text-right font-medium text-ink-900">{@value}</dd>
    </div>
    """
  end

  defp on_off(true), do: "on"
  defp on_off(_), do: "off"

  defp channel_kind(name) do
    case Arc.Channels.Channel.parse(name) do
      {:ok, channel} -> channel.type |> Atom.to_string() |> String.replace("_", " ")
      _ -> "unknown"
    end
  end
end
