defmodule ArcWeb.AdminComponents do
  @moduledoc """
  The dashboard's building blocks.

  Panels are separated by rules and background, not by shadows: this is an
  instrument, and the numbers should carry the page. Machine data — keys, channel
  names, socket ids — is set in mono; everything a person reads is not.
  """
  use Phoenix.Component
  use ArcWeb, :verified_routes

  import ArcWeb.CoreComponents, only: [icon: 1]

  @doc "The sticky page header: where you are, and what you can do here."
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :breadcrumb, :list, default: [], doc: "[{label, href}], innermost last"
  slot :status, doc: "a pill or two beside the title"
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="sticky top-0 z-30 border-b border-rule bg-paper/85 backdrop-blur">
      <div class="mx-auto flex max-w-5xl flex-wrap items-end justify-between gap-x-6 gap-y-3 px-5 py-4 sm:px-8">
        <div class="min-w-0">
          <nav :if={@breadcrumb != []} class="mb-1 flex items-center gap-1.5 text-xs text-ink-400">
            <span :for={{label, href} <- @breadcrumb} class="flex items-center gap-1.5">
              <a href={href} class="hover:text-ink-700">{label}</a>
              <.icon name="hero-chevron-right-mini" class="size-3" />
            </span>
          </nav>
          <div class="flex flex-wrap items-center gap-2.5">
            <h1 class="truncate text-xl font-semibold tracking-tight text-ink-900">{@title}</h1>
            {render_slot(@status)}
          </div>
          <p :if={@subtitle} class="mt-1 max-w-prose text-sm text-ink-500">{@subtitle}</p>
        </div>
        <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
    </header>
    """
  end

  @doc "The content column under a page header."
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def page_body(assigns) do
    ~H"""
    <div class={["mx-auto max-w-5xl px-5 py-6 sm:px-8", @class]}>{render_slot(@inner_block)}</div>
    """
  end

  @doc "A panel: a titled region of related information."
  attr :title, :string, default: nil
  attr :note, :string, default: nil, doc: "one line under the title, for context"
  attr :class, :string, default: nil
  attr :body_class, :string, default: "p-5"
  slot :actions
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section class={[
      "overflow-hidden rounded-[var(--radius-panel)] border border-rule bg-surface",
      @class
    ]}>
      <header
        :if={@title}
        class="flex flex-wrap items-center justify-between gap-2 border-b border-rule px-5 py-3"
      >
        <div>
          <h2 class="text-sm font-semibold text-ink-900">{@title}</h2>
          <p :if={@note} class="mt-0.5 text-xs text-ink-500">{@note}</p>
        </div>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </header>
      <div class={@body_class}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc """
  A measured value. `tone` is `:live` for anything sampled this second, `:plain`
  for settings and totals that only change when someone changes them.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :unit, :string, default: nil
  attr :id, :string, default: nil
  attr :tone, :atom, default: :plain, values: [:plain, :live]

  def readout(assigns) do
    ~H"""
    <div class="readout rounded-[var(--radius-panel)] border border-rule bg-surface px-4 py-3">
      <div class="flex items-center gap-1.5 text-xs text-ink-500">
        <span :if={@tone == :live} class="live-dot size-1.5 rounded-full bg-live-600"></span>
        {@label}
      </div>
      <div class="mt-1 flex items-baseline gap-1.5">
        <span
          id={@id}
          class={[
            "text-2xl font-semibold tracking-tight",
            @tone == :live && "text-live-700",
            @tone == :plain && "text-ink-900"
          ]}
        >
          {@value}
        </span>
        <span :if={@unit} class="text-xs text-ink-400">{@unit}</span>
      </div>
    </div>
    """
  end

  @doc """
  The live connection stream: one point per second, oldest on the left.

  Drawn from the aggregator's own samples, so it shows what the cluster actually
  did rather than an animation.
  """
  attr :points, :list, required: true
  attr :class, :string, default: "h-16 w-full text-live-600"
  attr :id, :string, default: nil

  def sparkline(assigns) do
    assigns = assign(assigns, :geometry, sparkline_geometry(assigns.points))

    ~H"""
    <svg
      :if={@geometry}
      id={@id}
      class={@class}
      viewBox="0 0 100 30"
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      <path d={@geometry.area} fill="currentColor" fill-opacity="0.12" />
      <path
        d={@geometry.line}
        fill="none"
        stroke="currentColor"
        stroke-width="1.25"
        stroke-linejoin="round"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke"
      />
      <circle cx="100" cy={@geometry.last_y} r="1.6" fill="currentColor" />
    </svg>
    <p :if={!@geometry} class={["flex items-center text-xs text-ink-400", @class]}>Collecting…</p>
    """
  end

  defp sparkline_geometry(points) when length(points) < 2, do: nil

  defp sparkline_geometry(points) do
    count = length(points)
    max = Enum.max(points)
    min = Enum.min(points)
    # A flat line sits in the middle of the band rather than along its floor.
    span = if max == min, do: max(max, 1) * 2, else: max - min
    floor_value = if max == min, do: min - span / 2, else: min

    coordinates =
      points
      |> Enum.with_index()
      |> Enum.map(fn {value, index} ->
        x = index / (count - 1) * 100
        y = 29 - (value - floor_value) / span * 28
        {Float.round(x, 2), Float.round(y, 2)}
      end)

    line = "M" <> Enum.map_join(coordinates, " ", fn {x, y} -> "#{x},#{y}" end)
    {_, last_y} = List.last(coordinates)

    %{line: line, area: line <> " L100,30 L0,30 Z", last_y: last_y}
  end

  attr :kind, :atom, default: :neutral, values: [:neutral, :live, :good, :bad, :warn]
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium",
      @kind == :neutral && "bg-paper text-ink-500 ring-1 ring-rule",
      @kind in [:live, :good] && "bg-live-100 text-live-700",
      @kind == :bad && "bg-rose-50 text-rose-700",
      @kind == :warn && "bg-amber-wash text-amber-ink ring-1 ring-amber-line/50",
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :href, :string, default: nil
  attr :method, :string, default: nil
  attr :navigate, :string, default: nil
  attr :variant, :atom, default: :secondary, values: [:primary, :secondary, :quiet, :danger]
  attr :icon, :string, default: nil
  attr :rest, :global, include: ~w(type data-confirm form name value disabled phx-click title)
  slot :inner_block, required: true

  def btn(assigns) do
    assigns =
      assign(assigns, :class, [
        "inline-flex items-center gap-1.5 rounded-[var(--radius-control)] px-3 py-1.5 text-sm font-medium transition-colors",
        "disabled:cursor-not-allowed disabled:opacity-50",
        assigns.variant == :primary && "bg-signal-600 text-white hover:bg-signal-700",
        assigns.variant == :secondary &&
          "border border-rule-strong bg-surface text-ink-800 hover:border-ink-300 hover:bg-paper",
        assigns.variant == :quiet && "text-ink-500 hover:bg-paper hover:text-ink-900",
        assigns.variant == :danger &&
          "border border-rose-600/30 bg-surface text-rose-700 hover:bg-rose-50"
      ])

    ~H"""
    <.link :if={@navigate} navigate={@navigate} class={@class} {@rest}>
      <.icon :if={@icon} name={@icon} class="size-4" />{render_slot(@inner_block)}
    </.link>
    <.link :if={@href} href={@href} method={@method || "get"} class={@class} {@rest}>
      <.icon :if={@icon} name={@icon} class="size-4" />{render_slot(@inner_block)}
    </.link>
    <button :if={!@href && !@navigate} class={@class} {@rest}>
      <.icon :if={@icon} name={@icon} class="size-4" />{render_slot(@inner_block)}
    </button>
    """
  end

  @doc "A value the operator will copy: an id, a key, a host."
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :id, :string, required: true
  attr :secret, :boolean, default: false

  def credential(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-4 border-b border-rule py-2.5 last:border-0">
      <dt class="text-sm text-ink-500">{@label}</dt>
      <dd class="flex min-w-0 items-center gap-2">
        <code
          id={@id}
          class={[
            "truncate rounded-[3px] px-1.5 py-0.5 font-mono text-[0.8rem]",
            @secret && "bg-amber-wash text-amber-ink",
            !@secret && "bg-paper text-ink-800"
          ]}
        >
          {@value}
        </code>
        <button
          type="button"
          data-copy={"#" <> @id}
          class="shrink-0 text-xs font-medium text-signal-600 hover:text-signal-700"
        >
          Copy
        </button>
      </dd>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, default: nil
  attr :content, :string, required: true

  def code_block(assigns) do
    ~H"""
    <figure class="overflow-hidden rounded-[var(--radius-panel)] border border-rule">
      <figcaption
        :if={@label}
        class="flex items-center justify-between border-b border-rule bg-paper px-3 py-1.5 text-xs text-ink-500"
      >
        {@label}
        <button
          type="button"
          data-copy={"#" <> @id}
          class="font-medium text-signal-600 hover:text-signal-700"
        >
          Copy
        </button>
      </figcaption>
      <pre
        id={@id}
        class="overflow-x-auto bg-ink-950 p-4 font-mono text-xs leading-relaxed text-ink-300"
      ><code>{@content}</code></pre>
    </figure>
    """
  end

  @doc "An empty state: says what is missing and what to do about it."
  attr :title, :string, required: true
  attr :body, :string, default: nil
  slot :action

  def empty(assigns) do
    ~H"""
    <div class="px-2 py-8 text-center">
      <p class="text-sm font-medium text-ink-800">{@title}</p>
      <p :if={@body} class="mx-auto mt-1 max-w-sm text-sm text-ink-500">{@body}</p>
      <div :if={@action != []} class="mt-4 flex justify-center">{render_slot(@action)}</div>
    </div>
    """
  end

  @doc "A table styled for dense data, with its own scroll on narrow screens."
  attr :class, :string, default: nil
  slot :head, required: true
  slot :inner_block, required: true

  def table(assigns) do
    ~H"""
    <div class="w-full max-w-full overflow-x-auto">
      <table class={["w-full min-w-[26rem] text-left text-sm", @class]}>
        <thead class="text-xs text-ink-500">
          <tr class="border-b border-rule [&>th]:whitespace-nowrap [&>th]:pr-4">
            {render_slot(@head)}
          </tr>
        </thead>
        <tbody class="divide-y divide-rule [&>tr>td]:pr-4">{render_slot(@inner_block)}</tbody>
      </table>
    </div>
    """
  end

  @doc "Thousands separators, so five figures stay readable at a glance."
  def fmt(nil), do: "—"

  def fmt(int) when is_integer(int) do
    int
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def fmt(other), do: to_string(other)

  def fmt_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def fmt_bytes(_), do: "—"

  def fmt_time(nil), do: "—"
  def fmt_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")

  @doc "Relative time for recent events, a date for older ones."
  def fmt_ago(nil), do: "—"

  def fmt_ago(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      seconds when seconds < 5 -> "just now"
      seconds when seconds < 60 -> "#{seconds}s ago"
      seconds when seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds when seconds < 604_800 -> "#{div(seconds, 86_400)}d ago"
      _ -> Calendar.strftime(at, "%Y-%m-%d")
    end
  end
end
