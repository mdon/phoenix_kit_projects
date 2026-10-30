defmodule PhoenixKitProjects.Web.Components.TimeInput do
  @moduledoc """
  Every place the module asks for a time of day: a date field (core's
  `date_input/1`, in the site's date format) and an hour and a minute select,
  with an AM/PM select only on a site whose `time_format` is the 12-hour
  clock (`PhoenixKitProjects.L10n.twelve_hour?/0`).

  Not the browser's `datetime-local` / `time` inputs: those draw the device's
  clock, so an iPad showed AM/PM on a site that runs on 24 hours (the boss,
  2026-10-30). The selects show the site's clock on every device.

  ## Posting

  The parts post under the field's name — `assignment[deadline][date]`,
  `[hour]`, `[minute]`, `[half]` — and `normalize/2` folds them back into the
  value the old inputs posted (`"2026-10-31T17:00"` for a date and time,
  `"17:00"` for a time alone, `""` for none), so every receiver keeps its
  parsing. A plain string still passes through unchanged.

      attrs = TimeInput.normalize(attrs, ~w(deadline start_time))

  Two components:

    * `datetime_input/1` — a day and a time (a deadline, a real start). An
      empty day is no value whatever the selects show.
    * `clock_input/1` — a time alone (a planned day's time, a log's start).
      Its hour has an empty choice: no time.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.DateInput, only: [date_input: 1]

  alias PhoenixKitProjects.L10n

  # ── Normalizing what was posted ─────────────────────────────────────

  @doc """
  Folds the posted parts of each of `fields` in `attrs` back into the string
  the browser's own inputs posted: `"YYYY-MM-DDTHH:MM"` for a part map with a
  `"date"`, `"HH:MM"` for one without, `""` for an empty one. Fields that are
  absent or already a string are left as they are.
  """
  @spec normalize(map(), [String.t()]) :: map()
  def normalize(attrs, fields) when is_map(attrs) do
    Enum.reduce(fields, attrs, fn field, acc ->
      case Map.get(acc, field) do
        %{} = parts -> Map.put(acc, field, fold(parts))
        _ -> acc
      end
    end)
  end

  def normalize(attrs, _fields), do: attrs

  @doc "One posted part map as the string `normalize/2` puts in its place."
  @spec fold(map()) :: String.t()
  def fold(%{"date" => date} = parts) do
    case {String.trim(to_string(date)), clock(parts)} do
      {"", _} -> ""
      {day, nil} -> day <> "T00:00"
      {day, time} -> day <> "T" <> time
    end
  end

  def fold(%{} = parts), do: clock(parts) || ""

  # `"HH:MM"` of the posted hour, minute and AM/PM, or nil for no hour.
  defp clock(parts) do
    with {h, ""} when h in 0..23 <- Integer.parse(to_string(parts["hour"] || "")) do
      m =
        case Integer.parse(to_string(parts["minute"] || "")) do
          {m, ""} when m in 0..59 -> m
          _ -> 0
        end

      pad(from_half(h, parts["half"])) <> ":" <> pad(m)
    else
      _ -> nil
    end
  end

  # A 12-hour hour (1–12) with its half; a 24-hour one passes through.
  defp from_half(12, "am"), do: 0
  defp from_half(12, "pm"), do: 12
  defp from_half(h, "pm") when h in 1..11, do: h + 12
  defp from_half(h, _half), do: h

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # ── Reading a value for the selects ────────────────────────────────

  @doc """
  `%{date: "YYYY-MM-DD" | "", hour: 0..23 | nil, minute: 0..59 | nil}` of a
  value: a stored instant (shown in the viewer's zone), a wall clock, a
  `Time`, a posted string or part map. Anything else is empty.
  """
  @spec parts(term()) :: %{date: String.t(), hour: integer() | nil, minute: integer() | nil}
  def parts(%DateTime{} = dt), do: dt |> L10n.local() |> DateTime.to_naive() |> parts()

  def parts(%NaiveDateTime{} = n),
    do: %{date: Date.to_iso8601(NaiveDateTime.to_date(n)), hour: n.hour, minute: n.minute}

  def parts(%Time{hour: h, minute: m}), do: %{date: "", hour: h, minute: m}
  def parts(%{} = posted), do: posted |> fold() |> parts()

  def parts(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      # An instant with its offset (a cast value held in the params): the
      # viewer's wall clock, as a stored one.
      match?({:ok, _, _}, DateTime.from_iso8601(text)) ->
        {:ok, dt, _} = DateTime.from_iso8601(text)
        parts(dt)

      match?({:ok, _}, NaiveDateTime.from_iso8601(pad_seconds(text))) ->
        {:ok, n} = NaiveDateTime.from_iso8601(pad_seconds(text))
        parts(n)

      match?({:ok, _}, Time.from_iso8601(pad_seconds(text))) ->
        {:ok, t} = Time.from_iso8601(pad_seconds(text))
        parts(t)

      match?({:ok, _}, Date.from_iso8601(text)) ->
        %{date: text, hour: nil, minute: nil}

      true ->
        empty()
    end
  end

  def parts(_), do: empty()

  defp empty, do: %{date: "", hour: nil, minute: nil}

  # `"2026-10-31T17:00"` / `"17:00"` → with seconds, as ISO 8601 wants.
  defp pad_seconds(text) do
    if Regex.match?(~r/(^|T)\d{2}:\d{2}$/, text), do: text <> ":00", else: text
  end

  # ── The components ─────────────────────────────────────────────────

  @doc """
  A day and a time. `field` (or `name` + `value`) is the form field; `id`
  prefixes the parts' ids (`<id>-date`, `<id>-hour`, `<id>-minute`,
  `<id>-half`). `default_hour` is what the hour shows while there is no
  value yet (a deadline is usually by the end of a working day).
  """
  attr(:id, :string, required: true)
  attr(:field, Phoenix.HTML.FormField, default: nil)
  attr(:name, :string, default: nil)
  attr(:value, :any, default: nil)
  attr(:label, :string, default: nil)
  attr(:default_hour, :integer, default: 9)
  attr(:required, :boolean, default: false)
  attr(:disabled, :boolean, default: false)

  attr(:form, :string,
    default: nil,
    doc: "the `form=` owner of the parts, for a field drawn outside its form"
  )

  attr(:size, :string, default: "sm", values: ~w(xs sm md))
  attr(:class, :any, default: nil)

  def datetime_input(assigns) do
    assigns = with_field(assigns)
    p = parts(assigns.value)

    assigns =
      assign(assigns,
        date: p.date,
        hour: p.hour || if(p.date == "", do: assigns.default_hour, else: 0),
        minute: p.minute || 0
      )

    ~H"""
    <fieldset id={@id} class={["flex flex-col gap-1", @class]} data-time-input="datetime">
      <legend :if={@label} class="label mb-1">
        <span class="font-semibold">{@label}</span>
        <span :if={@required} class="text-error ml-0.5" aria-hidden="true">*</span>
      </legend>
      <div class="flex flex-wrap items-center gap-1.5">
        <.date_input
          id={"#{@id}-date"}
          name={"#{@name}[date]"}
          value={@date}
          size={@size}
          bare
          wrapper_class="w-40"
          html={date_html(@form, @disabled)}
          aria-label={gettext("Day")}
        />
        <.clock_selects
          id={@id}
          name={@name}
          hour={@hour}
          minute={@minute}
          blank={false}
          form={@form}
          disabled={@disabled}
          size={@size}
        />
      </div>
      <p :for={msg <- @errors} class="text-error text-xs">{msg}</p>
    </fieldset>
    """
  end

  @doc """
  A time of day alone. The hour has an empty choice (no time); the minute
  follows it.
  """
  attr(:id, :string, required: true)
  attr(:field, Phoenix.HTML.FormField, default: nil)
  attr(:name, :string, default: nil)
  attr(:value, :any, default: nil)
  attr(:label, :string, default: nil)
  attr(:disabled, :boolean, default: false)
  attr(:form, :string, default: nil)
  attr(:size, :string, default: "sm", values: ~w(xs sm md))
  attr(:class, :any, default: nil)

  def clock_input(assigns) do
    assigns = with_field(assigns)
    p = parts(assigns.value)
    assigns = assign(assigns, hour: p.hour, minute: p.minute || 0)

    ~H"""
    <fieldset id={@id} class={["flex flex-col gap-1", @class]} data-time-input="clock">
      <legend :if={@label} class="label mb-1"><span class="font-semibold">{@label}</span></legend>
      <div class="flex flex-wrap items-center gap-1.5">
        <.clock_selects
          id={@id}
          name={@name}
          hour={@hour}
          minute={@minute}
          blank={true}
          form={@form}
          disabled={@disabled}
          size={@size}
        />
      </div>
      <p :for={msg <- @errors} class="text-error text-xs">{msg}</p>
    </fieldset>
    """
  end

  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:hour, :any, required: true)
  attr(:minute, :integer, required: true)
  attr(:blank, :boolean, required: true)
  attr(:form, :string, default: nil)
  attr(:disabled, :boolean, default: false)
  attr(:size, :string, default: "sm")

  defp clock_selects(assigns) do
    twelve? = L10n.twelve_hour?()

    {shown_hour, half} =
      case assigns.hour do
        nil -> {nil, "am"}
        h when twelve? -> {elem(L10n.to_twelve_hour(h), 0), if(h < 12, do: "am", else: "pm")}
        h -> {h, nil}
      end

    assigns =
      assign(assigns,
        twelve?: twelve?,
        shown_hour: shown_hour,
        half: half,
        hours: if(twelve?, do: [12 | Enum.to_list(1..11)], else: Enum.to_list(0..23)),
        minutes: minute_options(assigns.minute),
        select_class: "select select-#{assigns.size} w-auto"
      )

    ~H"""
    <select
      id={"#{@id}-hour"}
      name={"#{@name}[hour]"}
      form={@form}
      disabled={@disabled}
      class={@select_class}
      aria-label={gettext("Hour")}
    >
      <option :if={@blank} value="" selected={is_nil(@shown_hour)}>—</option>
      <option :for={h <- @hours} value={h} selected={h == @shown_hour}>
        {if @twelve?, do: Integer.to_string(h), else: pad(h)}
      </option>
    </select>
    <span class="text-base-content/60">:</span>
    <select
      id={"#{@id}-minute"}
      name={"#{@name}[minute]"}
      form={@form}
      disabled={@disabled}
      class={@select_class}
      aria-label={gettext("Minute")}
    >
      <option :for={m <- @minutes} value={m} selected={m == @minute}>{pad(m)}</option>
    </select>
    <select
      :if={@twelve?}
      id={"#{@id}-half"}
      name={"#{@name}[half]"}
      form={@form}
      disabled={@disabled}
      class={@select_class}
      aria-label={gettext("AM or PM")}
    >
      <option value="am" selected={@half == "am"}>{L10n.day_half_label("am")}</option>
      <option value="pm" selected={@half == "pm"}>{L10n.day_half_label("pm")}</option>
    </select>
    """
  end

  # Every five minutes, plus the value's own minute when it is between them
  # (a start stamped at 13:07 keeps its 07).
  defp minute_options(current) do
    steps = Enum.to_list(0..55//5)
    if current in steps, do: steps, else: Enum.sort([current | steps])
  end

  defp date_html(form, disabled) do
    %{}
    |> then(&if(form, do: Map.put(&1, :form, form), else: &1))
    |> then(&if(disabled, do: Map.put(&1, :disabled, true), else: &1))
  end

  defp with_field(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(:name, assigns.name || field.name)
    |> assign(:value, if(is_nil(assigns.value), do: field.value, else: assigns.value))
    |> assign(:errors, Enum.map(field.errors, &translate_error/1))
  end

  defp with_field(assigns), do: assign(assigns, :errors, [])

  # Core's, so a changeset error reads as in every other field.
  defp translate_error(error), do: PhoenixKitWeb.Components.Core.Input.translate_error(error)
end
