defmodule PhoenixKitProjects.Web.Components.FormParts do
  @moduledoc """
  The building blocks of the module's edit popups, lifted out of the task
  popup (the newest, the design the others follow — the boss, 2026-10-30:
  "the lack of tabs, the user assignment thing being different in basically
  every pop-up"):

    * `form_header/1` — where the record sits and what is happening to it
      on one line, and under it the record's name as it is being typed;
    * `form_tabs/1` — the tab strip over the panes of one form; every pane
      stays in the form and is only hidden, so a switch loses nothing
      typed and a save posts all of them; a tab holding an error carries a
      dot;
    * `form_pane/1` — one of those panes;
    * `words_block/1` — the language tabs (with the AI translate button)
      over the translatable fields, and only those: the wrapper re-mounts
      on a language switch;
    * `status_choices/1` — the status as a row of coloured choices, one
      press each.

  The assignee picker, the time pickers and the amount-of-time input are
  components of their own (`AssigneePicker`, `TimeInput`,
  `DurationInput`).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.MultilangForm, only: [multilang_fields_wrapper: 1]
  import PhoenixKitAI.Components.AITranslate, only: [ai_multilang_tabs: 1]

  alias PhoenixKitProjects.Web.Components.AssignmentStatusBadge

  # ── Header ─────────────────────────────────────────────────────────

  @doc """
  The popup's header: a context line (`:context` — the way back, the
  record's place; `mode` — "Editing", "Add task"; a close button when
  `close_event` is set) and the title, which the form keeps up to date as
  the name is typed. `:badge` sits beside the title (a status).
  """
  attr(:id, :string, required: true)
  attr(:title_id, :string, default: nil)
  attr(:title, :string, required: true)
  attr(:mode, :string, default: nil)
  attr(:close_event, :string, default: nil)

  attr(:close_confirm, :any,
    default: nil,
    doc: "a question asked before closing (unsaved changes)"
  )

  attr(:close_label, :string, default: nil)
  slot(:context)
  slot(:actions)
  slot(:badge)

  def form_header(assigns) do
    ~H"""
    <header id={@id} class="flex flex-col gap-1.5">
      <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm min-w-0">
        {render_slot(@context)}
        <span :if={@mode} class="text-base-content/50">{@mode}</span>
        <div class="ml-auto flex items-center gap-1">
          {render_slot(@actions)}
          <button
            :if={@close_event}
            type="button"
            phx-click={@close_event}
            data-confirm={@close_confirm}
            class="btn btn-ghost btn-sm btn-square"
            aria-label={@close_label || gettext("Close")}
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>
      </div>
      <div class="flex items-start gap-3">
        <h2
          id={@title_id || "#{@id}-title"}
          class="flex-1 min-w-0 text-xl font-semibold leading-snug break-words text-balance"
        >
          {@title}
        </h2>
        {render_slot(@badge)}
      </div>
    </header>
    """
  end

  # ── Tabs ───────────────────────────────────────────────────────────

  @doc """
  The tab strip of a form's panes: `panes` is `[{id, label}]`, `active` the
  open one, `errors` the panes holding an error (a `MapSet`). Each tab sends
  `event` with `pane`. Nothing is drawn for fewer than two panes. Tab ids
  are `<prefix>-tab-<pane>`, pane ids `<prefix>-pane-<pane>`.

  Tabs never jump (the panel, 2026-10-31): in a drawer (`PopupHost`) the
  form is a column — header, this strip, then the open pane as the one
  scroll area — so the strip sits outside what scrolls, and a switch to a
  shorter tab moves nothing. The `PkpTabScroll` hook takes the newly
  opened pane to its top, and does nothing on any other update.
  """
  attr(:id, :string, required: true)
  attr(:prefix, :string, required: true)
  attr(:panes, :list, required: true)
  attr(:active, :string, required: true)
  attr(:errors, :any, default: MapSet.new())
  attr(:event, :string, default: "set_form_pane")

  def form_tabs(assigns) do
    ~H"""
    <div
      :if={match?([_, _ | _], @panes)}
      role="tablist"
      class="tabs tabs-border shrink-0"
      id={@id}
      phx-hook="PkpTabScroll"
      data-pkp-tabs
      data-active={@active}
    >
      <button
        :for={{pane, label} <- @panes}
        type="button"
        role="tab"
        id={"#{@prefix}-tab-#{pane}"}
        aria-selected={to_string(@active == pane)}
        aria-controls={"#{@prefix}-pane-#{pane}"}
        phx-click={@event}
        phx-value-pane={pane}
        class={["tab gap-1.5", @active == pane && "tab-active"]}
      >
        {label}
        <span
          :if={MapSet.member?(@errors, pane)}
          class="inline-block w-2 h-2 rounded-full bg-error"
          title={gettext("Something here needs fixing")}
          data-pane-error={pane}
        ></span>
      </button>
    </div>
    """
  end

  @doc "One pane of a tabbed form: hidden, never removed, while another is open."
  attr(:prefix, :string, required: true)
  attr(:pane, :string, required: true)
  attr(:active, :string, required: true)
  attr(:class, :any, default: "flex flex-col gap-4")
  slot(:inner_block, required: true)

  def form_pane(assigns) do
    ~H"""
    <section
      id={"#{@prefix}-pane-#{@pane}"}
      role="tabpanel"
      aria-labelledby={"#{@prefix}-tab-#{@pane}"}
      class={[@class, @active != @pane && "hidden"]}
    >
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Which pane to show: `wanted` when it is one of `panes`, else the first.
  """
  @spec open_pane([{String.t(), String.t()}], String.t() | nil) :: String.t()
  def open_pane([{first, _} | _] = panes, wanted) do
    if Enum.any?(panes, &(elem(&1, 0) == wanted)), do: wanted, else: first
  end

  def open_pane([], wanted), do: wanted || ""

  @doc """
  The panes holding an error the form shows: `pane_of` maps a field (atom)
  to its pane, `changesets` are the forms' sources. Only a changeset with an
  action shows its errors.
  """
  @spec error_panes([Ecto.Changeset.t() | nil], %{atom() => String.t()}) :: MapSet.t()
  def error_panes(changesets, pane_of) do
    for %Ecto.Changeset{action: action, errors: errors} <- changesets,
        action != nil,
        {field, _} <- errors,
        pane = Map.get(pane_of, field),
        pane != nil,
        into: MapSet.new(),
        do: pane
  end

  # ── The words, per language ───────────────────────────────────────

  @doc """
  The language tabs (the AI translate button in their row) over the
  translatable fields — which go in the inner block, and nothing else:
  the wrapper re-mounts on a language switch. Framed when there is more
  than one language. `:skeleton` mirrors the fields while a switch loads.
  """
  attr(:id, :string, required: true)
  attr(:multilang_enabled, :boolean, required: true)
  attr(:language_tabs, :list, required: true)
  attr(:current_lang, :string, required: true)
  attr(:ai_translate, :any, default: nil)
  slot(:skeleton)
  slot(:inner_block, required: true)

  def words_block(assigns) do
    assigns =
      assign(assigns,
        translated?: assigns.multilang_enabled and match?([_, _ | _], assigns.language_tabs)
      )

    ~H"""
    <div id={@id} class={["flex flex-col gap-3", @translated? && "rounded-box border border-base-300 p-3"]}>
      <.ai_multilang_tabs
        :if={@multilang_enabled}
        multilang_enabled={@multilang_enabled}
        language_tabs={@language_tabs}
        current_lang={@current_lang}
        class=""
        ai_row_class="flex items-center gap-3 -mt-3"
        ai_translate={@ai_translate}
      />
      <.multilang_fields_wrapper
        multilang_enabled={@multilang_enabled}
        current_lang={@current_lang}
        skeleton_class="space-y-2"
        fields_class="flex flex-col gap-3"
      >
        <:skeleton>
          <%= if @skeleton != [] do %>
            {render_slot(@skeleton)}
          <% else %>
            <div class="space-y-2 mb-3">
              <div class="bg-base-content/15 rounded h-4 w-20 animate-pulse"></div>
              <div class="bg-base-content/15 rounded h-10 w-full animate-pulse"></div>
            </div>
            <div class="space-y-2">
              <div class="bg-base-content/15 rounded h-4 w-24 animate-pulse"></div>
              <div class="bg-base-content/15 rounded h-16 w-full animate-pulse"></div>
            </div>
          <% end %>
        </:skeleton>
        {render_slot(@inner_block)}
      </.multilang_fields_wrapper>
    </div>
    """
  end

  # ── Status ─────────────────────────────────────────────────────────

  @doc """
  The status as the list's own coloured badges, one press each — a radio
  group, so the choice posts with the form. `options` is `[{label, value}]`.
  """
  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:value, :string, required: true)
  attr(:options, :list, required: true)
  attr(:label, :string, default: nil)

  def status_choices(assigns) do
    ~H"""
    <fieldset id={@id}>
      <legend class="text-sm font-semibold mb-1.5">{@label || gettext("Status")}</legend>
      <div class="flex flex-wrap gap-1.5">
        <label
          :for={{label, value} <- @options}
          id={"#{@id}-#{value}"}
          class={status_choice_class(value, @value == value)}
        >
          <input type="radio" name={@name} value={value} checked={@value == value} class="sr-only" />
          <.icon :if={@value == value} name="hero-check-mini" class="w-4 h-4 -ml-0.5" />
          {label}
        </label>
      </div>
    </fieldset>
    """
  end

  @doc """
  The same coloured status choices as plain buttons, for a status changed
  at once rather than posted with a form (the "Change status" popup): each
  press sends `event` with `values` plus `"status" => value`; the current
  one is marked and pressed already.
  """
  attr(:id, :string, required: true)
  attr(:value, :string, default: nil, doc: "the status it has now")
  attr(:options, :list, required: true, doc: "`[{label, value}]`")
  attr(:event, :string, required: true)
  attr(:values, :map, default: %{}, doc: "sent with every press, beside `status`")
  attr(:target, :any, default: nil)

  def status_buttons(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap gap-1.5" role="group">
      <button
        :for={{label, value} <- @options}
        type="button"
        id={"#{@id}-#{value}"}
        phx-click={Phoenix.LiveView.JS.push(@event, value: Map.put(@values, "status", value), target: @target)}
        aria-pressed={to_string(@value == value)}
        class={status_choice_class(value, @value == value)}
      >
        <.icon :if={@value == value} name="hero-check-mini" class="w-4 h-4 -ml-0.5" />
        {label}
      </button>
    </div>
    """
  end

  # The chosen one filled, the others outlined in their own colour.
  defp status_choice_class(status, true) do
    [
      "badge badge-lg h-auto py-1.5 px-3 gap-1 cursor-pointer select-none font-semibold",
      "ring-2 ring-base-content/20 focus-within:outline focus-within:outline-2 focus-within:outline-offset-2",
      AssignmentStatusBadge.badge_class(status)
    ]
  end

  defp status_choice_class(status, false) do
    [
      "badge badge-lg badge-outline h-auto py-1.5 px-3 gap-1 cursor-pointer select-none",
      "opacity-80 hover:opacity-100 focus-within:outline focus-within:outline-2 focus-within:outline-offset-2",
      status_outline(status)
    ]
  end

  defp status_outline("todo"), do: "badge-info"
  defp status_outline("in_progress"), do: "badge-warning"
  defp status_outline("done"), do: "badge-success"
  defp status_outline(_), do: "text-base-content/70"
end
