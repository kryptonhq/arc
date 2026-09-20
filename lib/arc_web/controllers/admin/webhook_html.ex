defmodule ArcWeb.Admin.WebhookHTML do
  use ArcWeb, :html

  import ArcWeb.AdminComponents

  @descriptions %{
    "channel_occupied" => "the first subscriber joins a channel",
    "channel_vacated" => "the last subscriber leaves",
    "member_added" => "someone joins a presence channel",
    "member_removed" => "someone's last connection leaves a presence channel",
    "client_event" => "a client publishes to other clients",
    "cache_miss" => "a cache channel is subscribed to with nothing retained"
  }

  def index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header
        title="Webhooks"
        breadcrumb={[{"Apps", ~p"/admin/apps"}, {@app.name, ~p"/admin/apps/#{@app.id}"}]}
        subtitle="Arc calls your backend when channels fill and empty, so you can track occupancy without polling."
      />

      <.page_body>
        <div class="grid gap-6 lg:grid-cols-5">
          <div class="min-w-0 space-y-6 lg:col-span-3">
            <.panel title="Endpoints">
              <.empty
                :if={@endpoints == []}
                title="No endpoints yet"
                body="Add a URL and pick the events you care about. Arc batches events that happen close together into one request."
              />
              <ul :if={@endpoints != []} class="divide-y divide-rule">
                <li :for={endpoint <- @endpoints} class="flex items-start justify-between gap-4 py-3">
                  <div class="min-w-0">
                    <div class="flex items-center gap-2">
                      <code class="truncate font-mono text-xs text-ink-800">{endpoint.url}</code>
                      <.pill :if={!endpoint.active} kind={:warn}>paused</.pill>
                    </div>
                    <div class="mt-1.5 flex flex-wrap gap-1">
                      <.pill :for={event <- endpoint.events} kind={:neutral}>{event}</.pill>
                    </div>
                  </div>
                  <div class="flex shrink-0 gap-2">
                    <.btn
                      href={~p"/admin/apps/#{@app.id}/webhooks/#{endpoint.id}/edit"}
                      variant={:quiet}
                    >
                      Edit
                    </.btn>
                    <.btn
                      href={~p"/admin/apps/#{@app.id}/webhooks/#{endpoint.id}"}
                      method="delete"
                      variant={:danger}
                      data-confirm="Remove this endpoint? Arc stops calling it and its delivery history is removed."
                    >
                      Remove
                    </.btn>
                  </div>
                </li>
              </ul>
            </.panel>
          </div>

          <div class="min-w-0 lg:col-span-2">
            <.panel title="Add an endpoint">
              <.endpoint_form
                changeset={@changeset}
                action={~p"/admin/apps/#{@app.id}/webhooks"}
                submit="Add endpoint"
              />
            </.panel>

            <div class="mt-4 rounded-[var(--radius-panel)] border border-rule bg-paper px-4 py-3 text-xs leading-relaxed text-ink-500">
              <p>
                Each request carries <code class="font-mono">X-Pusher-Key</code>
                and <code class="font-mono">X-Pusher-Signature</code>, which your server SDK
                verifies against the app secret. Give the endpoint its own secret to get a
                second signature in <code class="font-mono">X-Arc-Signature</code>.
              </p>
              <p class="mt-2">
                Failures retry after 1s, 5s, 30s, 2m and 10m. A 4xx is treated as a
                misconfiguration and not retried.
              </p>
            </div>
          </div>
        </div>

        <.panel class="mt-6" title="Deliveries" note="Every attempt, newest first.">
          <.deliveries deliveries={@deliveries} />
        </.panel>
      </.page_body>
    </Layouts.app>
    """
  end

  def edit(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header
        title="Edit webhook endpoint"
        breadcrumb={[
          {"Apps", ~p"/admin/apps"},
          {@app.name, ~p"/admin/apps/#{@app.id}"},
          {"Webhooks", ~p"/admin/apps/#{@app.id}/webhooks"}
        ]}
      />
      <.page_body class="max-w-2xl">
        <.panel>
          <.endpoint_form
            changeset={@changeset}
            action={~p"/admin/apps/#{@app.id}/webhooks/#{@endpoint.id}"}
            method="put"
            submit="Save endpoint"
            active
            cancel={~p"/admin/apps/#{@app.id}/webhooks"}
          />
        </.panel>
      </.page_body>
    </Layouts.app>
    """
  end

  attr :changeset, :any, required: true
  attr :action, :string, required: true
  attr :method, :string, default: "post"
  attr :submit, :string, required: true
  attr :active, :boolean, default: false
  attr :cancel, :string, default: nil

  defp endpoint_form(assigns) do
    assigns =
      assign(assigns, :selected, Ecto.Changeset.get_field(assigns.changeset, :events) || [])

    ~H"""
    <.form
      :let={f}
      for={@changeset}
      as={:endpoint}
      action={@action}
      method={@method}
      class="space-y-5"
    >
      <.input
        field={f[:url]}
        type="url"
        label="URL"
        placeholder="https://example.com/webhooks/arc"
        required
      />
      <.input
        field={f[:secret]}
        type="password"
        label="Endpoint secret"
        value=""
        autocomplete="new-password"
        hint="Optional. Lets a receiver verify the request without holding the app secret."
      />

      <fieldset>
        <legend class="text-sm font-medium text-ink-800">Send these events</legend>
        <input type="hidden" name="endpoint[events][]" value="" />
        <div class="mt-2 space-y-2">
          <label
            :for={event <- Arc.Webhooks.event_types()}
            class="flex items-start gap-2.5 text-sm"
          >
            <input
              type="checkbox"
              name="endpoint[events][]"
              value={event}
              checked={event in @selected}
              class="mt-0.5 size-4 rounded-[3px] border-rule-strong text-signal-600 focus:ring-signal-600"
            />
            <span>
              <code class="font-mono text-xs text-ink-800">{event}</code>
              <span class="block text-xs text-ink-400">when {description(event)}</span>
            </span>
          </label>
        </div>
        <p
          :for={
            {msg, _} <- (@changeset.action && Keyword.get_values(@changeset.errors, :events)) || []
          }
          class="mt-2 text-sm text-rose-700"
        >
          {msg}
        </p>
      </fieldset>

      <.input :if={@active} field={f[:active]} type="checkbox" label="Endpoint is active" />

      <div class="flex items-center gap-2 border-t border-rule pt-5">
        <.btn variant={:primary} type="submit">{@submit}</.btn>
        <.btn :if={@cancel} href={@cancel} variant={:quiet}>Cancel</.btn>
      </div>
    </.form>
    """
  end

  attr :deliveries, :list, required: true
  attr :compact, :boolean, default: false

  def deliveries(assigns) do
    ~H"""
    <.empty
      :if={@deliveries == []}
      title="No deliveries yet"
      body="Deliveries appear here as soon as a channel fills or empties."
    />

    <.table :if={@deliveries != []}>
      <:head>
        <th class="py-2 font-medium">When</th>
        <th class="font-medium">Events</th>
        <th :if={!@compact} class="font-medium">Endpoint</th>
        <th class="font-medium">Status</th>
        <th class="text-right font-medium">Attempts</th>
      </:head>
      <tr :for={delivery <- @deliveries}>
        <td class="whitespace-nowrap py-2 text-ink-500" title={fmt_time(delivery.inserted_at)}>
          {fmt_ago(delivery.inserted_at)}
        </td>
        <td class="max-w-[18rem] py-2">
          <div class="truncate font-mono text-xs text-ink-800">{summary(delivery.payload)}</div>
          <div
            :if={delivery.last_error}
            class="truncate text-xs text-rose-700"
            title={delivery.last_error}
          >
            {delivery.last_error}
          </div>
        </td>
        <td :if={!@compact} class="max-w-[14rem] truncate font-mono text-xs text-ink-500">
          {delivery.endpoint && delivery.endpoint.url}
        </td>
        <td>
          <.pill kind={status_kind(delivery.status)}>{delivery.status}</.pill>
          <span
            :if={delivery.last_error}
            class="ml-1.5 text-xs text-rose-700"
            title={delivery.last_error}
          >
            {String.slice(delivery.last_error, 0, 40)}
          </span>
        </td>
        <td class="text-right tabular text-ink-500">{delivery.attempts}</td>
      </tr>
    </.table>
    """
  end

  defp summary(%{"events" => events}) when is_list(events) do
    Enum.map_join(events, ", ", fn event ->
      [event["name"], event["channel"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
    end)
  end

  defp summary(_), do: ""

  defp status_kind("delivered"), do: :good
  defp status_kind("failed"), do: :bad
  defp status_kind(_), do: :warn

  defp description(event), do: Map.get(@descriptions, event, event)
end
