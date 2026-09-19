defmodule ArcWeb.Admin.WebhookHTML do
  use ArcWeb, :html

  import ArcWeb.AdminComponents

  def index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header
        title={"Webhooks · #{@app.name}"}
        subtitle="Signed with the app secret in X-Pusher-Signature; an endpoint secret adds X-Arc-Signature."
      >
        <:actions>
          <.btn href={~p"/admin/apps/#{@app.id}"}>Back to app</.btn>
        </:actions>
      </.page_header>

      <div class="grid gap-6 lg:grid-cols-3">
        <.card title="Endpoints" class="lg:col-span-2">
          <p :if={@endpoints == []} class="text-sm text-zinc-500">No endpoints yet.</p>
          <ul class="divide-y divide-zinc-100">
            <li :for={endpoint <- @endpoints} class="flex items-start justify-between gap-4 py-3">
              <div class="min-w-0">
                <div class="truncate font-mono text-sm">{endpoint.url}</div>
                <div class="mt-1 flex flex-wrap gap-1">
                  <.badge :if={!endpoint.active} kind={:warn}>inactive</.badge>
                  <.badge :for={event <- endpoint.events}>{event}</.badge>
                </div>
              </div>
              <div class="flex shrink-0 gap-2">
                <.btn href={~p"/admin/apps/#{@app.id}/webhooks/#{endpoint.id}/edit"}>Edit</.btn>
                <.btn
                  href={~p"/admin/apps/#{@app.id}/webhooks/#{endpoint.id}"}
                  method="delete"
                  variant={:danger}
                  data-confirm="Remove this endpoint?"
                >
                  Remove
                </.btn>
              </div>
            </li>
          </ul>
        </.card>

        <.card title="Add endpoint">
          <.endpoint_form
            changeset={@changeset}
            action={~p"/admin/apps/#{@app.id}/webhooks"}
            submit="Add endpoint"
          />
        </.card>
      </div>

      <.card title="Delivery log" class="mt-6">
        <.deliveries deliveries={@deliveries} />
      </.card>
    </Layouts.app>
    """
  end

  def edit(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header title="Edit webhook endpoint">
        <:actions>
          <.btn href={~p"/admin/apps/#{@app.id}/webhooks"}>Back</.btn>
        </:actions>
      </.page_header>
      <.card class="max-w-xl">
        <.endpoint_form
          changeset={@changeset}
          action={~p"/admin/apps/#{@app.id}/webhooks/#{@endpoint.id}"}
          method="put"
          submit="Save"
          active
        />
      </.card>
    </Layouts.app>
    """
  end

  attr :changeset, :any, required: true
  attr :action, :string, required: true
  attr :method, :string, default: "post"
  attr :submit, :string, required: true
  attr :active, :boolean, default: false

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
      class="space-y-4"
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
        label="Endpoint secret (optional)"
        value=""
        autocomplete="new-password"
      />
      <fieldset>
        <legend class="mb-2 text-sm font-medium text-zinc-700">Events</legend>
        <input type="hidden" name="endpoint[events][]" value="" />
        <label
          :for={event <- Arc.Webhooks.event_types()}
          class="flex items-center gap-2 py-0.5 text-sm"
        >
          <input
            type="checkbox"
            name="endpoint[events][]"
            value={event}
            checked={event in @selected}
            class="rounded border-zinc-300"
          />
          <code>{event}</code>
        </label>
        <p
          :for={{msg, _} <- Keyword.get_values(@changeset.errors, :events)}
          class="mt-1 text-sm text-rose-600"
        >
          {msg}
        </p>
      </fieldset>
      <.input :if={@active} field={f[:active]} type="checkbox" label="Active" />
      <.btn variant={:primary} type="submit">{@submit}</.btn>
    </.form>
    """
  end

  attr :deliveries, :list, required: true

  def deliveries(assigns) do
    ~H"""
    <p :if={@deliveries == []} class="text-sm text-zinc-500">No deliveries yet.</p>
    <table :if={@deliveries != []} class="w-full text-left text-sm">
      <thead class="text-xs uppercase text-zinc-500">
        <tr>
          <th class="py-2">Time</th>
          <th>Endpoint</th>
          <th>Events</th>
          <th>Status</th>
          <th>Attempts</th>
          <th>Last error</th>
        </tr>
      </thead>
      <tbody class="divide-y divide-zinc-100">
        <tr :for={d <- @deliveries}>
          <td class="whitespace-nowrap py-2 text-zinc-500">{fmt_time(d.inserted_at)}</td>
          <td class="max-w-48 truncate font-mono text-xs">{d.endpoint && d.endpoint.url}</td>
          <td class="text-xs">
            {d.payload |> Map.get("events", []) |> Enum.map_join(", ", & &1["name"])}
          </td>
          <td>
            <.badge kind={status_kind(d.status)}>{d.status}</.badge>
          </td>
          <td class="tabular-nums">{d.attempts}</td>
          <td class="max-w-64 truncate text-xs text-rose-700" title={d.last_error}>{d.last_error}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp status_kind("delivered"), do: :good
  defp status_kind("failed"), do: :bad
  defp status_kind(_), do: :warn
end
