defmodule PhoenixKitProjects.Web.Components.AITranslateBarTest do
  @moduledoc """
  Rendering contract for `<.ai_translate_bar>`.

  The bar is pure-emit (no state of its own) — every visible
  affordance is driven by the `ai_translate` attr passed in by the
  host. These tests pin the rendering contract so a host LV (project,
  template, task form, or a custom embedder) can rely on:

    * `phx-click={event}` + `phx-value-lang={lang}` per missing lang
    * Bulk `phx-value-lang="*"` sentinel when ≥2 actionable
    * Spinner instead of sparkle when a lang is in_flight
    * Bulk button disabled while ANY lang is in_flight (closes the
      rapid-double-click gap surfaced by Phase 2 triage)
    * Hidden entirely when disabled, missing event name, or empty
      actionable set
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import PhoenixKitProjects.Web.Components.AITranslateBar

  defp bar(ai_translate) do
    render_component(&ai_translate_bar/1, ai_translate: ai_translate)
  end

  describe "visibility" do
    test "renders nothing when ai_translate is nil" do
      assert bar(nil) == ""
    end

    test "renders nothing when enabled: false" do
      assert bar(%{enabled: false, event: "x", missing: ["es"], in_flight: []}) == ""
    end

    test "renders nothing when event is blank" do
      assert bar(%{enabled: true, event: "", missing: ["es"], in_flight: []}) == ""
      assert bar(%{enabled: true, event: "   ", missing: ["es"], in_flight: []}) == ""
    end

    test "renders nothing when actionable missing list is empty" do
      assert bar(%{enabled: true, event: "x", missing: [], in_flight: []}) == ""
    end

    test "stays visible (as spinner) when every missing lang is in_flight" do
      # Regression: previously the bar gated visibility on
      # `actionable_missing/1` (= missing -- in_flight), which made
      # the whole bar unmount the moment the user clicked "es" on a
      # single-missing-lang resource: `missing: ["es"]`,
      # `in_flight: ["es"]` → actionable=[] → bar disappears
      # mid-translation. Now gated on `normalized_missing != []`, so
      # the disabled spinner button stays visible until the host
      # drops the lang from missing (on :translation_completed).
      cfg = %{enabled: true, event: "x", missing: ["es", "de"], in_flight: ["es", "de"]}
      html = bar(cfg)

      refute html == ""
      assert html =~ "loading-spinner"
      assert html =~ "btn-disabled"
      # Bulk button NOT shown — bulk_show?/1 still uses actionable_missing
      # so an "all in flight" state correctly suppresses the bulk CTA.
      refute html =~ ~s|phx-value-lang="*"|
    end

    test "single missing lang in_flight stays visible as spinner (single-click UX)" do
      # The common case: user has a project with 1 missing lang,
      # clicks the sparkle, the bar must show the spinner while the
      # job runs rather than disappearing.
      cfg = %{enabled: true, event: "x", missing: ["es"], in_flight: ["es"]}
      html = bar(cfg)

      refute html == ""
      assert html =~ "loading-spinner"
      assert html =~ ~s|phx-value-lang="es"|
      assert html =~ "btn-disabled"
    end
  end

  describe "per-language sparkle buttons" do
    test "renders one button per missing language with phx-click + phx-value-lang" do
      html =
        bar(%{
          enabled: true,
          event: "translate_lang",
          missing: ["es", "de", "fr"],
          in_flight: []
        })

      for lang <- ["es", "de", "fr"] do
        assert html =~ ~s|phx-click="translate_lang"|
        assert html =~ ~s|phx-value-lang="#{lang}"|
      end
    end

    test "in-flight language renders a spinner and disables the button" do
      html =
        bar(%{
          enabled: true,
          event: "translate_lang",
          missing: ["es", "de"],
          in_flight: ["es"]
        })

      # Look for the in-flight es button by its phx-value-lang. The
      # exact spinner class comes from daisyUI's `loading loading-spinner`.
      assert html =~ ~s|phx-value-lang="es"|
      assert html =~ "loading-spinner"
      assert html =~ "btn-disabled"
    end

    test "non-in-flight language renders sparkle icon (hero-sparkles)" do
      html =
        bar(%{
          enabled: true,
          event: "translate_lang",
          missing: ["es"],
          in_flight: []
        })

      assert html =~ "hero-sparkles"
    end

    test "aria-label encodes the uppercased target lang code" do
      html =
        bar(%{
          enabled: true,
          event: "translate_lang",
          missing: ["pt-br"],
          in_flight: []
        })

      assert html =~ ~s|aria-label="Translate to PT-BR"|
    end
  end

  describe "bulk CTA" do
    test "renders bulk button with phx-value-lang=\"*\" when ≥2 actionable" do
      html =
        bar(%{
          enabled: true,
          event: "translate_lang",
          missing: ["es", "de"],
          in_flight: []
        })

      assert html =~ ~s|phx-value-lang="*"|
      assert html =~ "Translate all (2)"
    end

    test "no bulk button when only 1 actionable language" do
      html =
        bar(%{
          enabled: true,
          event: "translate_lang",
          missing: ["es"],
          in_flight: []
        })

      refute html =~ ~s|phx-value-lang="*"|
      refute html =~ "Translate all"
    end

    test "bulk button disabled when any in-flight (Phase 2 fix)" do
      # Phase 2 triage finding: clicking "Translate all (N)" twice in
      # rapid succession would visually leave the button primary-blue
      # while the second click hit Oban's unique-constraint silently.
      # The fix: `bulk_busy?/1` looks at `missing -- (missing -- in_flight)`
      # — any in_flight intersection disables the bulk button.
      html =
        bar(%{
          enabled: true,
          event: "translate_lang",
          missing: ["es", "de", "fr"],
          in_flight: ["es"]
        })

      assert html =~ "btn-disabled"
      # Sanity: the bulk button is still rendered (just disabled).
      assert html =~ ~s|phx-value-lang="*"|
    end

    test "bulk count subtracts in-flight (only counts actionable)" do
      # 4 missing, 1 in-flight → actionable = 3
      html =
        bar(%{
          enabled: true,
          event: "translate_lang",
          missing: ["es", "de", "fr", "it"],
          in_flight: ["es"]
        })

      assert html =~ "Translate all (3)"
    end
  end

  describe "weird-input handling — defensive against host bugs" do
    test "atom lang codes are coerced to strings (don't crash gettext.String.upcase)" do
      html =
        bar(%{
          enabled: true,
          event: "translate_lang",
          missing: [:es, :de],
          in_flight: []
        })

      assert html =~ ~s|phx-value-lang="es"|
      assert html =~ ~s|phx-value-lang="de"|
      assert html =~ "Translate to ES"
    end

    test "blank / whitespace-only lang codes are dropped" do
      html =
        bar(%{
          enabled: true,
          event: "translate_lang",
          missing: ["es", "", "  ", nil],
          in_flight: []
        })

      assert html =~ ~s|phx-value-lang="es"|
      # No empty `phx-value-lang=""` rendered
      refute html =~ ~s|phx-value-lang=""|
      # No empty aria-label
      refute html =~ ~s|aria-label="Translate to "|
    end

    test "non-binary, non-atom missing entries are dropped silently (host bug, fail closed)" do
      html =
        bar(%{
          enabled: true,
          event: "translate_lang",
          missing: ["es", 123, {:tuple, :nope}, %{}],
          in_flight: []
        })

      assert html =~ ~s|phx-value-lang="es"|
      # Bulk button needs ≥2 actionable; only "es" survived
      refute html =~ ~s|phx-value-lang="*"|
    end

    test "all-blank missing list renders nothing (no orphan bar with just label)" do
      assert bar(%{
               enabled: true,
               event: "translate_lang",
               missing: ["", nil, "   "],
               in_flight: []
             }) == ""
    end

    test "in_flight list with atom entries matches against normalized missing" do
      # Host might pass `[:es]` for in_flight while `missing` is string-keyed.
      # Both sides should normalize, so `:es` in_flight matches `"es"` missing.
      html =
        bar(%{
          enabled: true,
          event: "translate_lang",
          missing: ["es", "de"],
          in_flight: [:es]
        })

      # `es` should render as disabled spinner, not sparkle
      assert html =~ "loading-spinner"
      assert html =~ "btn-disabled"
    end

    test "non-map ai_translate (e.g. a list passed by mistake) returns nothing" do
      # The component pattern-matches on `is_map/1` in visible?/1; any
      # non-map input falls through to the nil clause.
      assert bar([]) == ""
      assert bar(:enabled) == ""
      assert bar("string") == ""
    end
  end

  describe "string-keyed config (JSON / JSONB hosts)" do
    test "accepts string keys equivalently to atom keys" do
      atom_html =
        bar(%{
          enabled: true,
          event: "translate_lang",
          missing: ["es"],
          in_flight: []
        })

      string_html =
        bar(%{
          "enabled" => true,
          "event" => "translate_lang",
          "missing" => ["es"],
          "in_flight" => []
        })

      # Both should produce the same per-button affordances. The exact
      # whitespace may differ from EEx rendering, so compare the
      # button-shaped pieces individually.
      assert atom_html =~ ~s|phx-value-lang="es"|
      assert string_html =~ ~s|phx-value-lang="es"|
      assert atom_html =~ "hero-sparkles"
      assert string_html =~ "hero-sparkles"
    end
  end
end
