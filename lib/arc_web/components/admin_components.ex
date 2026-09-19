defmodule ArcWeb.AdminComponents do
  @moduledoc "Building blocks for the dashboard pages."
  use Phoenix.Component
  use ArcWeb, :verified_routes

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 class="text-2xl font-semibold tracking-tight">{@title}</h1>
        <p :if={@subtitle} class="mt-1 text-sm text-zinc-500">{@subtitle}</p>
      </div>
      <div class="flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  attr :title, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true
  slot :actions

  def card(assigns) do
    ~H"""
    <section class={["rounded-xl border border-zinc-200 bg-white shadow-sm", @class]}>
      <header
        :if={@title}
        class="flex items-center justify-between border-b border-zinc-100 px-5 py-3"
      >
        <h2 class="text-sm font-semibold text-zinc-800">{@title}</h2>
        <div class="flex items-center gap-2">{render_slot(@actions)}</div>
      </header>
      <div class="p-5">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :id, :string, default: nil

  def stat(assigns) do
    ~H"""
    <div class="rounded-xl border border-zinc-200 bg-white px-5 py-4 shadow-sm">
      <dt class="text-xs font-medium uppercase tracking-wide text-zinc-500">{@label}</dt>
      <dd id={@id} class="mt-1 text-2xl font-semibold tabular-nums">{@value}</dd>
    </div>
    """
  end

  attr :kind, :atom, default: :neutral, values: [:neutral, :good, :bad, :warn]
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
      @kind == :neutral && "bg-zinc-100 text-zinc-700",
      @kind == :good && "bg-emerald-50 text-emerald-700",
      @kind == :bad && "bg-rose-50 text-rose-700",
      @kind == :warn && "bg-amber-50 text-amber-700"
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :href, :string, default: nil
  attr :method, :string, default: nil
  attr :variant, :atom, default: :secondary, values: [:primary, :secondary, :danger]
  attr :rest, :global, include: ~w(type data-confirm form name value disabled)
  slot :inner_block, required: true

  def btn(assigns) do
    assigns =
      assign(assigns, :class, [
        "inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium shadow-sm transition-colors",
        assigns.variant == :primary && "bg-indigo-600 text-white hover:bg-indigo-500",
        assigns.variant == :secondary &&
          "border border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50",
        assigns.variant == :danger && "bg-rose-600 text-white hover:bg-rose-500"
      ])

    ~H"""
    <.link :if={@href} href={@href} method={@method || "get"} class={@class} {@rest}>{render_slot(
      @inner_block
    )}</.link>
    <button :if={!@href} class={@class} {@rest}>{render_slot(@inner_block)}</button>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, default: nil
  attr :content, :string, required: true

  def code_block(assigns) do
    ~H"""
    <div class="relative">
      <div :if={@label} class="mb-1 text-xs font-medium text-zinc-500">{@label}</div>
      <pre
        id={@id}
        class="overflow-x-auto rounded-lg bg-zinc-900 p-4 text-xs leading-relaxed text-zinc-100"
      ><code>{@content}</code></pre>
      <button
        type="button"
        data-copy={"#" <> @id}
        class="absolute right-2 top-7 rounded-md bg-zinc-700 px-2 py-1 text-xs text-zinc-100 hover:bg-zinc-600"
      >
        Copy
      </button>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :id, :string, required: true
  attr :secret, :boolean, default: false

  def credential(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-4 border-b border-zinc-100 py-2 last:border-0">
      <dt class="text-sm text-zinc-500">{@label}</dt>
      <dd class="flex items-center gap-2">
        <code
          id={@id}
          class={[
            "rounded px-2 py-0.5 font-mono text-sm",
            @secret && "bg-amber-50 text-amber-900",
            !@secret && "bg-zinc-100"
          ]}
        >{@value}</code>
        <button
          type="button"
          data-copy={"#" <> @id}
          class="text-xs font-medium text-indigo-600 hover:text-indigo-500"
        >Copy</button>
      </dd>
    </div>
    """
  end

  @doc "Human-friendly integer formatting: 12,345."
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
end
