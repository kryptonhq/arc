defmodule ArcWeb.AuthHTML do
  use ArcWeb, :html

  def forbidden(assigns) do
    ~H"""
    <Layouts.bare>
      <h1 class="text-xl font-semibold text-zinc-900">Access denied</h1>
      <p class="mt-2 text-sm text-zinc-600">{@message}</p>
      <a
        href={~p"/auth/logout"}
        class="mt-6 inline-block text-sm font-medium text-indigo-600 hover:text-indigo-500"
      >
        Sign in with a different account
      </a>
    </Layouts.bare>
    """
  end

  def error(assigns) do
    ~H"""
    <Layouts.bare>
      <h1 class="text-xl font-semibold text-zinc-900">Sign-in failed</h1>
      <p class="mt-2 text-sm text-zinc-600">{@message}</p>
      <a
        href={~p"/auth/login"}
        class="mt-6 inline-block text-sm font-medium text-indigo-600 hover:text-indigo-500"
      >
        Try again
      </a>
    </Layouts.bare>
    """
  end
end
