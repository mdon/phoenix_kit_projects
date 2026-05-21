defmodule PhoenixKitProjects.Web.Components.AITranslateBarTest do
  @moduledoc """
  Rendering contract for `<.ai_translate_button>` + `<.ai_translate_modal>`.

  The pair replaced the earlier 40-button inline bar (unusable when
  apps have many enabled languages) with publishing's editor-style
  trigger-plus-modal pattern. Both components are pure-emit — every
  visible state is driven by the `ai_translate` attr the host LV
  computes from its socket assigns.

  Tests pin the rendering contract so a host LV (project, template,
  task form, or a custom embedder) can rely on:

    * trigger button shows a missing-count badge or spinner badge
    * modal renders endpoint/prompt selects with current selections
    * modal action buttons disable correctly when prerequisites are
      missing (no endpoint, no prompt, anything in flight)
    * graceful failure: nil / non-map / blank-event configs render
      nothing rather than crashing
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import PhoenixKitProjects.Web.Components.AITranslateBar

  defp button(ai_translate),
    do: render_component(&ai_translate_button/1, ai_translate: ai_translate)

  defp modal(ai_translate),
    do: render_component(&ai_translate_modal/1, ai_translate: ai_translate)

  defp full_cfg(overrides) do
    Map.merge(
      %{
        enabled: true,
        event: "translate_lang",
        toggle_event: "toggle_ai",
        select_endpoint_event: "sel_ep",
        select_prompt_event: "sel_p",
        generate_prompt_event: "gen_p",
        missing: ["es", "de"],
        in_flight: [],
        modal_open: false,
        endpoints: [{"ep-uuid", "OpenAI"}],
        prompts: [{"p-uuid", "Default"}],
        selected_endpoint_uuid: "ep-uuid",
        selected_prompt_uuid: "p-uuid",
        default_prompt_exists: true,
        current_lang: "es",
        primary_lang: "en"
      },
      overrides
    )
  end

  describe "ai_translate_button/1 — visibility" do
    test "renders nothing when ai_translate is nil" do
      assert button(nil) == ""
    end

    test "renders nothing when enabled: false" do
      assert button(full_cfg(%{enabled: false})) == ""
    end

    test "renders nothing when toggle_event is blank" do
      assert button(full_cfg(%{toggle_event: ""})) == ""
      assert button(full_cfg(%{toggle_event: "   "})) == ""
    end

    test "renders nothing when there's nothing to translate and nothing in flight" do
      assert button(full_cfg(%{missing: [], in_flight: []})) == ""
    end

    test "renders when there are missing langs" do
      html = button(full_cfg(%{missing: ["es"], in_flight: []}))
      assert html =~ "AI Translate"
      assert html =~ ~s|phx-click="toggle_ai"|
    end

    test "renders when there are in-flight langs even with no remaining missing" do
      # User clicked translate, job is running, the only missing lang
      # is now in_flight — the trigger should still show the spinner
      # badge so the user can re-open the modal to check status.
      html = button(full_cfg(%{missing: ["es"], in_flight: ["es"]}))
      refute html == ""
      assert html =~ "loading-spinner"
    end

    test "non-map ai_translate falls back to hidden" do
      assert button([]) == ""
      assert button(:atom) == ""
      assert button("string") == ""
    end
  end

  describe "ai_translate_button/1 — badge content" do
    test "missing count badge when nothing in flight" do
      html = button(full_cfg(%{missing: ["es", "de", "fr"], in_flight: []}))
      assert html =~ "3 missing"
      refute html =~ "loading-spinner"
    end

    test "spinner badge when any lang in flight (takes precedence over missing count)" do
      html = button(full_cfg(%{missing: ["es", "de"], in_flight: ["es"]}))
      assert html =~ "loading-spinner"
      # Badge shows count of in-flight langs (not missing)
      assert html =~ "badge-primary"
    end

    test "aria-expanded reflects modal_open" do
      assert button(full_cfg(%{modal_open: false})) =~ ~s|aria-expanded="false"|
      assert button(full_cfg(%{modal_open: true})) =~ ~s|aria-expanded="true"|
    end
  end

  describe "ai_translate_modal/1 — visibility" do
    test "renders nothing when ai_translate is nil" do
      assert modal(nil) == ""
    end

    test "renders nothing when enabled: false" do
      assert modal(full_cfg(%{enabled: false})) == ""
    end

    test "renders nothing when toggle_event is blank" do
      assert modal(full_cfg(%{toggle_event: ""})) == ""
    end

    test "is renderable but not open by default" do
      html = modal(full_cfg(%{modal_open: false}))
      # The <dialog> element is still in the DOM (renderable) but
      # without the `modal-open` class — daisyUI hides it.
      assert html =~ "ai-translation-modal"
      refute html =~ "modal-open"
    end

    test "opens when modal_open: true" do
      html = modal(full_cfg(%{modal_open: true}))
      assert html =~ "modal-open"
    end
  end

  describe "ai_translate_modal/1 — endpoint selector" do
    test "renders the endpoints list as options" do
      html =
        modal(
          full_cfg(%{
            modal_open: true,
            endpoints: [{"ep-1", "OpenAI"}, {"ep-2", "Claude"}]
          })
        )

      assert html =~ ~s|<option value="ep-1"|
      assert html =~ "OpenAI"
      assert html =~ ~s|<option value="ep-2"|
      assert html =~ "Claude"
    end

    test "marks the selected endpoint as `selected`" do
      html =
        modal(
          full_cfg(%{
            modal_open: true,
            endpoints: [{"ep-1", "OpenAI"}, {"ep-2", "Claude"}],
            selected_endpoint_uuid: "ep-2"
          })
        )

      assert html =~ ~s|<option value="ep-2" selected|
    end

    test "wires phx-change to select_endpoint_event" do
      html = modal(full_cfg(%{modal_open: true}))
      assert html =~ ~s|phx-change="sel_ep"|
    end

    test "empty endpoints list still renders the prompt placeholder option" do
      html = modal(full_cfg(%{modal_open: true, endpoints: []}))
      assert html =~ "Select an endpoint"
    end
  end

  describe "ai_translate_modal/1 — prompt selector + generate-default" do
    test "renders Generate Default Prompt button when no default exists" do
      html =
        modal(full_cfg(%{modal_open: true, default_prompt_exists: false}))

      assert html =~ "Generate Default Prompt"
      assert html =~ ~s|phx-click="gen_p"|
    end

    test "hides Generate Default Prompt button when default already exists" do
      html = modal(full_cfg(%{modal_open: true, default_prompt_exists: true}))
      refute html =~ "Generate Default Prompt"
    end
  end

  describe "ai_translate_modal/1 — action buttons" do
    test "renders Translate Missing button with phx-value-lang=\"*\"" do
      html =
        modal(
          full_cfg(%{
            modal_open: true,
            missing: ["es", "de"],
            in_flight: []
          })
        )

      assert html =~ ~s|phx-value-lang="*"|
      assert html =~ "Translate Missing Only (2)"
    end

    test "Translate Missing disabled when no endpoint selected" do
      html =
        modal(
          full_cfg(%{
            modal_open: true,
            selected_endpoint_uuid: nil
          })
        )

      assert html =~ "btn-disabled"
    end

    test "Translate Missing disabled when no prompt selected" do
      html =
        modal(
          full_cfg(%{
            modal_open: true,
            selected_prompt_uuid: nil
          })
        )

      assert html =~ "btn-disabled"
    end

    test "Translate Missing disabled while any lang in flight" do
      html =
        modal(
          full_cfg(%{
            modal_open: true,
            missing: ["es", "de"],
            in_flight: ["es"]
          })
        )

      assert html =~ "btn-disabled"
    end

    test "hides Translate Missing when actionable_missing is empty" do
      html =
        modal(
          full_cfg(%{
            modal_open: true,
            missing: ["es"],
            in_flight: ["es"]
          })
        )

      refute html =~ ~s|phx-value-lang="*"|
    end

    test "renders Translate to Current button when on a non-primary lang in missing" do
      html =
        modal(
          full_cfg(%{
            modal_open: true,
            current_lang: "es",
            primary_lang: "en",
            missing: ["es", "de"]
          })
        )

      assert html =~ ~s|phx-value-lang="es"|
      assert html =~ "Translate to ES"
    end

    test "hides Translate to Current when on the primary lang" do
      html =
        modal(
          full_cfg(%{
            modal_open: true,
            current_lang: "en",
            primary_lang: "en",
            missing: ["es"]
          })
        )

      refute html =~ "Translate to EN"
    end

    test "hides Translate to Current when current_lang isn't in missing (already translated)" do
      html =
        modal(
          full_cfg(%{
            modal_open: true,
            current_lang: "fr",
            primary_lang: "en",
            missing: ["es", "de"]
          })
        )

      refute html =~ "Translate to FR"
    end
  end

  describe "ai_translate_modal/1 — status panel" do
    test "shows in-flight alert listing the langs currently translating" do
      html =
        modal(
          full_cfg(%{
            modal_open: true,
            missing: ["es", "de"],
            in_flight: ["es", "de"]
          })
        )

      assert html =~ "loading-spinner"
      assert html =~ "ES, DE"
    end

    test "shows 'all already translated' message when nothing to do" do
      html =
        modal(
          full_cfg(%{
            modal_open: true,
            missing: [],
            in_flight: [],
            current_lang: "en",
            primary_lang: "en"
          })
        )

      assert html =~ "All enabled languages already have translations"
    end
  end

  describe "weird-input handling" do
    test "atom lang codes are normalized in the trigger badge" do
      html = button(full_cfg(%{missing: [:es, :de], in_flight: []}))
      assert html =~ "2 missing"
    end

    test "blank / nil entries in missing are dropped" do
      html = button(full_cfg(%{missing: ["es", "", nil, "  "], in_flight: []}))
      assert html =~ "1 missing"
    end

    test "non-binary, non-atom entries are dropped silently" do
      html = button(full_cfg(%{missing: ["es", 123, %{}, {:tuple}], in_flight: []}))
      assert html =~ "1 missing"
    end
  end

  describe "string-keyed config (JSON / JSONB hosts)" do
    test "accepts string keys equivalently to atom keys" do
      atom_html = button(full_cfg(%{missing: ["es"]}))

      string_cfg =
        full_cfg(%{}) |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

      string_html = button(Map.put(string_cfg, "missing", ["es"]))

      assert atom_html =~ "AI Translate"
      assert string_html =~ "AI Translate"
    end
  end

  describe "backward-compat alias ai_translate_bar/1" do
    test "still forwards to the new button surface" do
      html = render_component(&ai_translate_bar/1, ai_translate: full_cfg(%{missing: ["es"]}))
      assert html =~ "AI Translate"
    end
  end
end
