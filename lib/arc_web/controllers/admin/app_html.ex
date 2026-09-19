defmodule ArcWeb.Admin.AppHTML do
  use ArcWeb, :html

  import ArcWeb.AdminComponents

  def new(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header
        title="New app"
        subtitle="An app isolates connections, channels, and credentials."
      />
      <.card class="max-w-xl">
        <.app_form changeset={@changeset} action={~p"/admin/apps"} submit="Create app" full={false} />
      </.card>
    </Layouts.app>
    """
  end

  def edit(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header title={"Settings · #{@app.name}"}>
        <:actions>
          <.btn href={~p"/admin/apps/#{@app.id}"}>Back to app</.btn>
        </:actions>
      </.page_header>
      <.card class="max-w-xl">
        <.app_form
          changeset={@changeset}
          action={~p"/admin/apps/#{@app.id}"}
          method="put"
          submit="Save settings"
          full={true}
        />
      </.card>
    </Layouts.app>
    """
  end

  attr :changeset, :any, required: true
  attr :action, :string, required: true
  attr :method, :string, default: "post"
  attr :submit, :string, required: true
  attr :full, :boolean, default: false

  defp app_form(assigns) do
    ~H"""
    <.form :let={f} for={@changeset} as={:app} action={@action} method={@method} class="space-y-4">
      <.input field={f[:name]} type="text" label="Name" required />
      <.input
        field={f[:client_events_enabled]}
        type="checkbox"
        label="Allow client events on private and presence channels"
      />
      <.input
        field={f[:max_connections]}
        type="number"
        label="Connection limit (blank for unlimited)"
        min="1"
      />
      <%= if @full do %>
        <.input
          field={f[:enabled]}
          type="checkbox"
          label="Enabled (disabling closes every connection)"
        />
        <.input
          field={f[:enable_presence_limits]}
          type="checkbox"
          label="Enforce the presence member ceiling"
        />
        <.input
          field={f[:max_presence_members]}
          type="number"
          label="Presence member ceiling"
          min="1"
        />
        <.input
          field={f[:max_payload_bytes]}
          type="number"
          label="Maximum event payload (bytes)"
          min="1024"
        />
        <.input
          field={f[:subscription_count_enabled]}
          type="checkbox"
          label="Allow subscription_count queries (cluster-wide count)"
        />
      <% end %>
      <div class="pt-2">
        <.btn variant={:primary} type="submit">{@submit}</.btn>
      </div>
    </.form>
    """
  end

  def credentials(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header title={@heading}>
        <:actions>
          <.btn href={~p"/admin/apps/#{@app.id}"} variant={:primary}>Go to app</.btn>
        </:actions>
      </.page_header>

      <div class="mb-6 rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
        <strong>Copy the secret now.</strong>
        It is shown on this page only and cannot be displayed again. If it is lost, rotate it from the app's page.
      </div>

      <div class="grid gap-6 lg:grid-cols-2">
        <.card title="Credentials">
          <dl>
            <.credential id="cred-app-id" label="App ID" value={to_string(@app.id)} />
            <.credential id="cred-key" label="Key" value={@app.key} />
            <.credential id="cred-secret" label="Secret" value={@secret} secret />
            <.credential id="cred-host" label="Host" value={ArcWeb.Snippets.public_endpoint().host} />
            <.credential
              id="cred-port"
              label="Port"
              value={to_string(ArcWeb.Snippets.public_endpoint().port)}
            />
          </dl>
        </.card>
        <div class="space-y-6">
          <.code_block
            id="snippet-django"
            label="Django settings.py"
            content={ArcWeb.Snippets.django(@app, @secret)}
          />
          <.code_block
            id="snippet-js"
            label="Browser client"
            content={ArcWeb.Snippets.javascript(@app)}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  def master_key(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header title="Encryption master key">
        <:actions>
          <.btn href={~p"/admin/apps/#{@app.id}"} variant={:primary}>Go to app</.btn>
        </:actions>
      </.page_header>
      <div class="mb-6 rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
        <strong>Copy the key now.</strong>
        Your backend passes it to its server SDK (for example <code>encryption_master_key_base64</code>) to encrypt
        events for <code>private-encrypted-</code>
        channels. It is not shown again.
      </div>
      <.card class="max-w-2xl">
        <dl>
          <.credential id="master-key" label="Master key (base64)" value={@master_key} secret />
        </dl>
      </.card>
    </Layouts.app>
    """
  end
end
