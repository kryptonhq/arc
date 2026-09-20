defmodule ArcWeb.Layouts do
  @moduledoc """
  The dashboard shell.

  A fixed rail on the left carries navigation and a live readout, so the numbers that
  matter — connections, messages per second, nodes — stay in view on every page. The
  main column holds a sticky header with the page's context and actions, then content.
  """
  use ArcWeb, :html

  import ArcWeb.AdminComponents

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_admin, :map, default: nil
  attr :active, :atom, default: nil, doc: "the highlighted navigation item"
  attr :stats, :map, default: nil, doc: "the latest cluster snapshot, when the page has one"

  slot :inner_block, required: true

  def app(assigns) do
    # Controller-rendered pages do not carry a snapshot; read one so the rail's
    # numbers are present on every page, not only the live ones.
    assigns = if assigns.stats, do: assigns, else: assign(assigns, :stats, rail_stats())

    ~H"""
    <div class="min-h-dvh lg:grid lg:grid-cols-[15rem_1fr]">
      <.rail active={@active} current_admin={@current_admin} stats={@stats} />

      <div class="min-w-0">
        <p
          :if={Arc.Admin.password_enabled?()}
          class="border-b border-amber-200 bg-amber-50 px-6 py-1.5 text-xs text-amber-900"
        >
          Password sign-in is enabled. Use an identity provider for shared or production
          installations.
        </p>
        {render_slot(@inner_block)}
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :active, :atom, default: nil
  attr :current_admin, :map, default: nil
  attr :stats, :map, default: nil

  defp rail(assigns) do
    ~H"""
    <div class="bg-ink-900 text-ink-300 lg:sticky lg:top-0 lg:h-dvh lg:overflow-y-auto">
      <!-- The live numbers re-render every second; without this the menu would
           close itself as soon as it was opened. -->
      <details id="mobile-nav" phx-update="ignore" class="group lg:hidden">
        <summary class="flex cursor-pointer list-none items-center justify-between px-5 py-4">
          <.wordmark />
          <span class="flex items-center gap-1 text-sm text-ink-300">
            Menu
            <.icon
              name="hero-chevron-down-mini"
              class="size-4 transition-transform group-open:rotate-180"
            />
          </span>
        </summary>
        <nav class="border-t border-ink-800 px-3 py-3">
          <.rail_links active={@active} />
          <div
            :if={@current_admin}
            class="mt-3 border-t border-ink-800 px-3 pt-3 text-xs text-ink-400"
          >
            <p class="truncate text-ink-300">{@current_admin.email}</p>
            <a href={~p"/auth/logout"} class="mt-1 inline-block hover:text-surface">Sign out</a>
          </div>
        </nav>
      </details>

      <div class="hidden px-5 py-4 lg:block">
        <a href={~p"/admin"} class="flex items-center gap-2.5 text-surface">
          <.wordmark />
        </a>
      </div>

      <nav class="hidden px-3 lg:block">
        <.rail_links active={@active} />
      </nav>

      <div :if={@stats} class="mt-6 hidden border-t border-ink-800 px-5 pt-5 lg:block">
        <.rail_readout stats={@stats} />
      </div>

      <div
        :if={@current_admin}
        class="hidden px-5 py-5 text-xs text-ink-400 lg:absolute lg:bottom-0 lg:block lg:w-60"
      >
        <p class="truncate text-ink-300">{@current_admin.email}</p>
        <a href={~p"/auth/logout"} class="mt-1 inline-block text-ink-400 hover:text-surface">
          Sign out
        </a>
      </div>
    </div>
    """
  end

  defp wordmark(assigns) do
    ~H"""
    <span class="flex items-center gap-2">
      <svg viewBox="0 0 24 24" class="size-5" aria-hidden="true" fill="none">
        <path
          d="M3 18a9 9 0 0 1 18 0"
          stroke="currentColor"
          stroke-width="2.25"
          stroke-linecap="round"
          class="text-live-600"
        />
        <circle cx="12" cy="18" r="1.75" fill="currentColor" class="text-surface" />
      </svg>
      <span class="text-[0.95rem] font-semibold tracking-tight text-surface">Arc</span>
    </span>
    """
  end

  attr :active, :atom, default: nil

  defp rail_links(assigns) do
    ~H"""
    <ul class="space-y-0.5 text-sm">
      <.rail_link href={~p"/admin"} icon="hero-signal" active={@active == :overview}>
        Overview
      </.rail_link>
      <.rail_link href={~p"/admin/apps"} icon="hero-square-3-stack-3d" active={@active == :apps}>
        Apps
      </.rail_link>
      <.rail_link href={~p"/admin/audit"} icon="hero-clock" active={@active == :audit}>
        Audit log
      </.rail_link>
    </ul>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp rail_link(assigns) do
    ~H"""
    <li>
      <a
        href={@href}
        aria-current={@active && "page"}
        class={[
          "flex items-center gap-2.5 rounded-[var(--radius-control)] px-3 py-2 transition-colors",
          @active && "bg-ink-800 font-medium text-surface",
          !@active && "text-ink-300 hover:bg-ink-800/60 hover:text-surface"
        ]}
      >
        <.icon name={@icon} class="size-4 shrink-0" />
        {render_slot(@inner_block)}
      </a>
    </li>
    """
  end

  attr :stats, :map, required: true

  defp rail_readout(assigns) do
    ~H"""
    <div class="readout">
      <div class="flex items-baseline gap-2">
        <span class="live-dot mt-px size-1.5 rounded-full bg-live-600"></span>
        <span class="text-2xl font-semibold tracking-tight text-surface">
          {fmt(@stats.connections)}
        </span>
        <span class="text-xs text-ink-400">connections</span>
      </div>

      <.sparkline
        points={Enum.map(@stats[:history] || [], & &1.connections)}
        class="mt-3 h-8 w-full text-live-600"
      />

      <dl class="mt-4 space-y-1.5 text-xs">
        <div class="flex justify-between">
          <dt class="text-ink-400">Messages / second</dt>
          <dd class="text-ink-300">{fmt(@stats.messages_per_second)}</dd>
        </div>
        <div class="flex justify-between">
          <dt class="text-ink-400">Nodes</dt>
          <dd class="text-ink-300">{length(@stats.nodes)}</dd>
        </div>
      </dl>
    </div>
    """
  end

  defp rail_stats do
    Arc.Metrics.Aggregator.snapshot()
    |> Map.put(:history, Arc.Metrics.Aggregator.history())
  rescue
    _ -> nil
  end

  @doc "A centred panel for pages outside the dashboard, such as sign-in problems."
  slot :inner_block, required: true

  def bare(assigns) do
    ~H"""
    <div class="flex min-h-dvh items-center justify-center px-4 py-16">
      <div class="w-full max-w-md rounded-[var(--radius-panel)] border border-rule bg-surface p-8">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
