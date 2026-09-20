defmodule ArcWeb.Admin.AppHTML do
  use ArcWeb, :html

  import ArcWeb.AdminComponents

  def new(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header
        title="New app"
        breadcrumb={[{"Apps", ~p"/admin/apps"}]}
        subtitle="An app is one set of credentials with its own channels. Most installations have one per product."
      />
      <.page_body class="max-w-2xl">
        <.panel>
          <.app_form
            changeset={@changeset}
            action={~p"/admin/apps"}
            submit="Create app"
            full={false}
          />
        </.panel>
      </.page_body>
    </Layouts.app>
    """
  end

  def edit(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header
        title="Settings"
        breadcrumb={[{"Apps", ~p"/admin/apps"}, {@app.name, ~p"/admin/apps/#{@app.id}"}]}
        subtitle="Limits apply to every connection and every publish for this app, on every node."
      />
      <.page_body class="max-w-2xl">
        <.panel>
          <.app_form
            changeset={@changeset}
            action={~p"/admin/apps/#{@app.id}"}
            method="put"
            submit="Save settings"
            full={true}
            cancel={~p"/admin/apps/#{@app.id}"}
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
  attr :full, :boolean, default: false
  attr :cancel, :string, default: nil

  defp app_form(assigns) do
    ~H"""
    <.form :let={f} for={@changeset} as={:app} action={@action} method={@method} class="space-y-5">
      <.input field={f[:name]} type="text" label="Name" required />

      <.input
        field={f[:client_events_enabled]}
        type="checkbox"
        label="Let clients publish events to each other"
        hint="Client events travel between subscribers of private and presence channels without reaching your backend. Limited to 10 per second per connection."
      />

      <.input
        field={f[:max_connections]}
        type="number"
        label="Connection limit"
        min="1"
        hint="Leave blank for unlimited. Connections past the limit are refused and told not to retry."
      />

      <div :if={@full} class="space-y-5 border-t border-rule pt-5">
        <.input
          field={f[:enabled]}
          type="checkbox"
          label="App is enabled"
          hint="Turning this off closes every connection for this app and refuses new ones."
        />
        <.input
          field={f[:enable_presence_limits]}
          type="checkbox"
          label="Cap presence channel size"
        />
        <.input
          field={f[:max_presence_members]}
          type="number"
          label="Members per presence channel"
          min="1"
          hint="Someone joining a full channel gets a subscription error rather than a truncated member list."
        />
        <.input
          field={f[:max_payload_bytes]}
          type="number"
          label="Largest event payload (bytes)"
          min="1024"
          hint="Publishes above this are refused with 413."
        />
        <.input
          field={f[:subscription_count_enabled]}
          type="checkbox"
          label="Answer subscription_count queries"
          hint="Counting subscribers asks every node, so it is off unless a backend needs it."
        />
      </div>

      <div class="flex items-center gap-2 border-t border-rule pt-5">
        <.btn variant={:primary} type="submit">{@submit}</.btn>
        <.btn :if={@cancel} href={@cancel} variant={:quiet}>Cancel</.btn>
      </div>
    </.form>
    """
  end

  def credentials(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header title={@heading} breadcrumb={[{"Apps", ~p"/admin/apps"}]}>
        <:actions>
          <.btn navigate={~p"/admin/apps/#{@app.id}"} variant={:primary}>Done</.btn>
        </:actions>
      </.page_header>

      <.page_body>
        <div class="mb-6 flex gap-3 rounded-[var(--radius-panel)] border border-amber-line/60 bg-amber-wash px-4 py-3 text-sm text-amber-ink">
          <.icon name="hero-key" class="mt-0.5 size-4 shrink-0" />
          <p>
            <strong class="font-semibold">Copy the secret now.</strong>
            This is the only time it is shown. If it is lost, rotate the secret from the app
            and update your backends with the new one.
          </p>
        </div>

        <div class="grid gap-6 lg:grid-cols-2">
          <.panel title="Credentials">
            <dl>
              <.credential id="cred-app-id" label="App id" value={to_string(@app.id)} />
              <.credential id="cred-key" label="Key" value={@app.key} />
              <.credential id="cred-secret" label="Secret" value={@secret} secret />
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
          </.panel>

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
      </.page_body>
    </Layouts.app>
    """
  end

  def master_key(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin} active={:apps}>
      <.page_header
        title="Encryption master key"
        breadcrumb={[{"Apps", ~p"/admin/apps"}, {@app.name, ~p"/admin/apps/#{@app.id}"}]}
      >
        <:actions>
          <.btn navigate={~p"/admin/apps/#{@app.id}"} variant={:primary}>Done</.btn>
        </:actions>
      </.page_header>

      <.page_body class="max-w-2xl">
        <div class="mb-6 flex gap-3 rounded-[var(--radius-panel)] border border-amber-line/60 bg-amber-wash px-4 py-3 text-sm text-amber-ink">
          <.icon name="hero-lock-closed" class="mt-0.5 size-4 shrink-0" />
          <p>
            <strong class="font-semibold">Copy the key now.</strong>
            Your backend passes it to its server SDK as
            <code class="font-mono text-xs">encryption_master_key_base64</code>
            to encrypt events for <code class="font-mono text-xs">private-encrypted-</code>
            channels. It is not shown again.
          </p>
        </div>

        <.panel title="Master key">
          <dl>
            <.credential id="master-key" label="Key (base64)" value={@master_key} secret />
          </dl>
        </.panel>
      </.page_body>
    </Layouts.app>
    """
  end
end
