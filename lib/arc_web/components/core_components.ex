defmodule ArcWeb.CoreComponents do
  @moduledoc """
  Form inputs, flash messages, and icons, styled with Arc's tokens (`assets/css/app.css`).

  Anything larger than a form control lives in `ArcWeb.AdminComponents`.
  """
  use Phoenix.Component
  use Gettext, backend: ArcWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  One flash message. Flashes report what just happened, so they are short, in the
  same words as the action that produced them.
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed bottom-4 right-4 z-50 w-80 cursor-pointer rounded-[var(--radius-panel)] border bg-surface p-4 text-sm shadow-[0_8px_24px_-12px_rgba(13,23,32,0.35)]",
        @kind == :info && "border-live-600/40",
        @kind == :error && "border-rose-600/40"
      ]}
      {@rest}
    >
      <p :if={@title} class="mb-1 font-semibold">{@title}</p>
      <p class={[@kind == :error && "text-rose-700"]}>{msg}</p>
      <p class="mt-2 text-xs text-ink-400">Click to dismiss</p>
    </div>
    """
  end

  @doc "Renders the flashes, including the ones LiveView raises when it loses the server."
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
        title={gettext("No connection to the server")}
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        {gettext("Reconnecting. Live numbers are paused.")}
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("The server went away")}
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        {gettext("Reconnecting. Live numbers are paused.")}
      </.flash>
    </div>
    """
  end

  @doc """
  A labelled form control.

  Supports the input types this dashboard uses; anything else falls through to a
  plain text input.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :hint, :string, default: nil, doc: "one line under the control explaining the effect"
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox number password select text textarea url)

  attr :field, Phoenix.HTML.FormField
  attr :errors, :list, default: []
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false

  attr :rest, :global, include: ~w(accept autocomplete disabled form max maxlength min minlength
                pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div>
      <label class="flex items-start gap-2.5 text-sm">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class="mt-0.5 size-4 rounded-[3px] border-rule-strong text-signal-600 focus:ring-signal-600"
          {@rest}
        />
        <span>
          {@label}
          <span :if={@hint} class="block text-xs text-ink-400">{@hint}</span>
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div>
      <.label for={@id}>{@label}</.label>
      <select id={@id} name={@name} class={control_class(@errors)} multiple={@multiple} {@rest}>
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <p :if={@hint} class="mt-1 text-xs text-ink-400">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <.label for={@id}>{@label}</.label>
      <textarea id={@id} name={@name} class={[control_class(@errors), "min-h-24"]} {@rest}>{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint} class="mt-1 text-xs text-ink-400">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div>
      <.label for={@id}>{@label}</.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={control_class(@errors)}
        {@rest}
      />
      <p :if={@hint} class="mt-1 text-xs text-ink-400">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp control_class(errors) do
    [
      "mt-1.5 block w-full rounded-[var(--radius-control)] border bg-surface px-3 py-2 text-sm text-ink-900",
      "placeholder:text-ink-300 focus:border-signal-600 focus:outline-none focus:ring-1 focus:ring-signal-600",
      errors == [] && "border-rule-strong",
      errors != [] && "border-rose-600"
    ]
  end

  attr :for, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label :if={render_slot(@inner_block) != []} for={@for} class="text-sm font-medium text-ink-800">
      {render_slot(@inner_block)}
    </label>
    """
  end

  @doc "An error under a form control. Errors say what to change, not that something is invalid."
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-1 flex items-center gap-1 text-sm text-rose-700">
      <.icon name="hero-exclamation-circle-mini" class="size-4" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc "A heroicon, by name."
  attr :name, :string, required: true
  attr :class, :string, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS helpers

  def show(js \\ %JS{}, selector) do
    JS.remove_attribute(js, "hidden", to: selector)
  end

  def hide(js \\ %JS{}, selector) do
    JS.set_attribute(js, {"hidden", ""}, to: selector)
  end

  @doc false
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(ArcWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(ArcWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc false
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
