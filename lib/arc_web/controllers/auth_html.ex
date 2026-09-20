defmodule ArcWeb.AuthHTML do
  use ArcWeb, :html

  import ArcWeb.AdminComponents

  def login(assigns) do
    ~H"""
    <Layouts.bare>
      <h1 class="text-lg font-semibold tracking-tight text-ink-900">Sign in to Arc</h1>
      <div :if={@oidc?} class="mt-6">
        <.btn href={~p"/auth/oidc"} variant={:primary}>Sign in with your identity provider</.btn>
        <p class="mt-6 text-xs uppercase tracking-wide text-ink-500">Or with the password</p>
      </div>
      <form method="post" action={~p"/auth/password"} class="mt-4 space-y-4">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <div>
          <label for="password" class="block text-sm font-medium text-ink-700">Password</label>
          <input
            type="password"
            name="password"
            id="password"
            autocomplete="current-password"
            required
            autofocus
            class="mt-1 w-full rounded-md border border-rule bg-surface px-3 py-2 text-sm text-ink-900 focus:border-ink-500 focus:outline-none"
          />
        </div>
        <p :if={@error} class="text-sm text-red-700" role="alert">{@error}</p>
        <.btn type="submit" variant={:primary}>Sign in</.btn>
      </form>
      <p class="mt-6 text-xs text-ink-500">
        The password is <code class="font-mono">ARC_ADMIN_PASSWORD</code> on the server.
        Use an identity provider for shared or production installations.
      </p>
    </Layouts.bare>
    """
  end

  def forbidden(assigns) do
    ~H"""
    <Layouts.bare>
      <h1 class="text-lg font-semibold tracking-tight text-ink-900">You can't open this dashboard</h1>
      <p class="mt-2 text-sm text-ink-500">{@message}</p>
      <p class="mt-4 text-sm text-ink-500">
        Administrators are listed in <code class="font-mono text-xs">ARC_ADMIN_EMAILS</code>
        on the server. Ask whoever runs this installation to add you.
      </p>
      <div class="mt-6">
        <.btn href={~p"/auth/logout"}>Sign in as someone else</.btn>
      </div>
    </Layouts.bare>
    """
  end

  def error(assigns) do
    ~H"""
    <Layouts.bare>
      <h1 class="text-lg font-semibold tracking-tight text-ink-900">Sign-in didn't finish</h1>
      <p class="mt-2 text-sm text-ink-500">{@message}</p>
      <div class="mt-6">
        <.btn href={~p"/auth/login"} variant={:primary}>Try again</.btn>
      </div>
    </Layouts.bare>
    """
  end
end
