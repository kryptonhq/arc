defmodule ArcWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ArcWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  The dashboard shell: top navigation, the signed-in admin, and page content.
  """
  attr :flash, :map, required: true
  attr :current_admin, :map, default: nil
  attr :active, :atom, default: nil, doc: "the highlighted navigation item"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-full">
      <nav class="border-b border-zinc-200 bg-white">
        <div class="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 sm:px-6">
          <div class="flex items-center gap-8">
            <a href={~p"/admin"} class="flex items-center gap-2 font-semibold tracking-tight">
              <span class="inline-block size-2.5 rounded-full bg-indigo-500"></span> Arc
            </a>
            <div class="flex gap-1 text-sm">
              <.nav_link href={~p"/admin"} active={@active == :overview}>Overview</.nav_link>
              <.nav_link href={~p"/admin/apps"} active={@active == :apps}>Apps</.nav_link>
              <.nav_link href={~p"/admin/audit"} active={@active == :audit}>Audit log</.nav_link>
            </div>
          </div>
          <div :if={@current_admin} class="flex items-center gap-4 text-sm text-zinc-500">
            <span>{@current_admin.email}</span>
            <a href={~p"/auth/logout"} class="font-medium text-zinc-700 hover:text-zinc-900">Sign out</a>
          </div>
        </div>
      </nav>

      <main class="mx-auto max-w-6xl px-4 py-8 sm:px-6">
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "rounded-md px-3 py-1.5 transition-colors",
        @active && "bg-zinc-100 font-medium text-zinc-900",
        !@active && "text-zinc-600 hover:bg-zinc-50 hover:text-zinc-900"
      ]}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  @doc "A centered card for pages outside the dashboard, such as sign-in errors."
  slot :inner_block, required: true

  def bare(assigns) do
    ~H"""
    <div class="flex min-h-full items-center justify-center px-4 py-16">
      <div class="w-full max-w-md rounded-xl border border-zinc-200 bg-white p-8 shadow-sm">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
