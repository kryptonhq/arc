defmodule ArcWeb.AuthHTML do
  use ArcWeb, :html

  import ArcWeb.AdminComponents

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
