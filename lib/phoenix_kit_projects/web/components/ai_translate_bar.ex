defmodule PhoenixKitProjects.Web.Components.AITranslateBar do
  @moduledoc """
  Compact AI-translation affordance rendered above the multilang tabs
  on project, template, and task forms.

  The bar drives `PhoenixKit.Modules.AI.Translation` end-to-end:

    * Computes the missing-language list from a resource's
      `translations` map and the host's `language_tabs`.
    * Renders a per-language `✨` button for every actionable missing
      language, plus a bulk "Translate all missing (N)" CTA when ≥2
      languages can be enqueued at once.
    * Reflects in-flight jobs by swapping the sparkle for a spinner
      and disabling the button while the host's `in_flight` set
      includes that language.

  ## Why a projects-side bar and not just the dropdown's `ai_translate`?

  Core's `<.language_switcher_dropdown>` exposes the same surface
  (PR #557) but the multilang-tabs UI used by projects forms doesn't
  pass through the dropdown — it uses the `:tabs` variant directly.
  Lifting `ai_translate` into the underlying `<.language_switcher>`
  would balloon PR #557. This bar reuses the same `phx-click` /
  `phx-value-lang` contract so a host can wire one handler regardless
  of which surface clicked it.

  ## Host contract

  - Pass `ai_translate: %{enabled: ..., event: ..., missing: [...], in_flight: [...]}`.
    `missing` is the list of *base* language codes (e.g. `["es", "de"]`)
    that have no translation yet. `in_flight` is the subset currently
    being translated by Oban jobs.
  - When AI is unavailable (`ai_translate.enabled == false`) the bar
    renders nothing — guard once at the host level via
    `PhoenixKitProjects.Translations.ai_translation_available?/0`.
  - Handle `phx-click={@ai_translate.event}` events: a `"lang"` value
    of `"*"` is the bulk sentinel (translate every actionable
    language). Any other value is a single base code.

  ## Reuse from a host LV outside this module

  The component itself only renders the buttons — it doesn't compute
  the `missing` / `in_flight` lists. A host LV embedding `<.ai_translate_bar>`
  from outside the project / template / task forms must:

  1. Have `language_tabs` and `primary_language` assigns set on the
     socket (the multilang form components from
     `PhoenixKitWeb.Components.MultilangForm` set these via
     `mount_multilang/1`). Hosts that don't already use that helper
     can compute `language_tabs` from
     `PhoenixKit.LanguageSettings.enabled_languages/0`.
  2. Track an `:ai_translate_in_flight` list assign (`[String.t()]`)
     and update it in response to `:translation_started` /
     `:translation_completed` / `:translation_failed` PubSub messages.
  3. Compute `missing` from the resource's `translations` JSONB. The
     contract is "no language with at least one non-blank
     translatable field" — see `has_any_translation?/3` in
     `project_form_live.ex` for the reference implementation.
  4. Subscribe (only when connected) to either
     `PhoenixKitProjects.PubSub.topic_project(uuid)` for project /
     template resources or `topic_tasks/0` for task resources. Both
     are narrower than `topic_all/0`.
  5. Implement a `handle_event(@ai_translate.event, %{"lang" => lang}, socket)`
     clause that calls `PhoenixKitProjects.Translations.enqueue/1`
     (single lang) or `enqueue_all_missing/2` (the `"*"` sentinel).
     Use the `:in_flight` list returned from `enqueue_all_missing/2`
     to update the spinner state — failed enqueues will not receive
     a worker broadcast and must be excluded from the spinner.

  See `language_switcher.ex` in core for the matching dropdown
  variant with `ai_translate` — it has the same per-language
  `phx-click` / `phx-value-lang` contract, so a host event handler
  works for either surface.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKitWeb.Components.Core.Icon

  attr(:ai_translate, :map,
    default: nil,
    doc: """
    Map of `:enabled` / `:event` / `:missing` / `:in_flight`. `nil`
    or `enabled: false` hides the bar entirely.
    """
  )

  attr(:class, :string, default: "flex items-center gap-2 px-4 py-2 border-b border-base-200")

  def ai_translate_bar(assigns) do
    ~H"""
    <%= if visible?(@ai_translate) do %>
      <div class={@class}>
        <Icon.icon name="hero-sparkles" class="w-4 h-4 text-primary shrink-0" />
        <span class="text-xs text-base-content/70 shrink-0">
          {gettext("AI translation")}
        </span>

        <div class="flex flex-wrap gap-1.5 ml-auto">
          <%= for lang <- actionable_missing(@ai_translate) do %>
            <button
              type="button"
              class={[
                "btn btn-xs gap-1",
                if(in_flight?(@ai_translate, lang), do: "btn-disabled", else: "btn-ghost")
              ]}
              phx-click={event_name(@ai_translate)}
              phx-value-lang={lang}
              disabled={in_flight?(@ai_translate, lang)}
              aria-label={gettext("Translate to %{lang}", lang: String.upcase(lang))}
            >
              <%= if in_flight?(@ai_translate, lang) do %>
                <span class="loading loading-spinner loading-xs"></span>
              <% else %>
                <Icon.icon name="hero-sparkles" class="w-3.5 h-3.5" />
              <% end %>
              <span class="font-mono uppercase">{lang}</span>
            </button>
          <% end %>

          <%= if bulk_show?(@ai_translate) do %>
            <button
              type="button"
              class={[
                "btn btn-xs gap-1",
                if(bulk_busy?(@ai_translate), do: "btn-disabled", else: "btn-primary")
              ]}
              phx-click={event_name(@ai_translate)}
              phx-value-lang="*"
              disabled={bulk_busy?(@ai_translate)}
            >
              <%= if bulk_busy?(@ai_translate) do %>
                <span class="loading loading-spinner loading-xs"></span>
              <% else %>
                <Icon.icon name="hero-sparkles" class="w-3.5 h-3.5" />
              <% end %>
              <span>
                {gettext("Translate all (%{count})", count: length(actionable_missing(@ai_translate)))}
              </span>
            </button>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp visible?(nil), do: false

  defp visible?(cfg) when is_map(cfg) do
    enabled?(cfg) and event_name(cfg) != nil and actionable_missing(cfg) != []
  end

  defp enabled?(cfg), do: get(cfg, :enabled) == true

  defp actionable_missing(cfg) do
    missing = cfg |> get(:missing) |> List.wrap()
    in_flight = cfg |> get(:in_flight) |> List.wrap()
    Enum.reject(missing, &(&1 in in_flight))
  end

  defp bulk_show?(cfg), do: length(actionable_missing(cfg)) >= 2

  # Bulk button is busy when any missing-language job is already
  # in flight. Without this, a user could click "Translate all (N)"
  # twice before the first `:translation_started` broadcast arrives;
  # the second click hits Oban's unique constraint, but visually the
  # button stays primary and clickable until the broadcast lands.
  defp bulk_busy?(cfg) do
    missing = cfg |> get(:missing) |> List.wrap()
    in_flight = cfg |> get(:in_flight) |> List.wrap()
    Enum.any?(missing, &(&1 in in_flight))
  end

  defp in_flight?(cfg, lang) do
    cfg |> get(:in_flight) |> List.wrap() |> Enum.member?(lang)
  end

  defp event_name(cfg) do
    case get(cfg, :event) do
      nil -> nil
      "" -> nil
      ev when is_binary(ev) -> if String.trim(ev) == "", do: nil, else: ev
      _ -> nil
    end
  end

  defp get(cfg, key) when is_atom(key) do
    case Map.fetch(cfg, key) do
      {:ok, v} -> v
      :error -> Map.get(cfg, Atom.to_string(key))
    end
  end
end
