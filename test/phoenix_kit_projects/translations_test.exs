defmodule PhoenixKitProjects.TranslationsTest do
  @moduledoc """
  Argument-validation coverage for `PhoenixKitProjects.Translations`.

  End-to-end coverage (the Oban worker doing the actual AI call) lives
  in `translate_resource_worker_test.exs` — it stubs the AI plugin
  presence and verifies the storage + broadcast paths.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.Translations

  # Helper: build a valid param map. UUID-shaped values pass the
  # `Ecto.UUID.cast/1` gate in `validate_params/1`.
  defp valid_params(overrides \\ %{}) do
    Map.merge(
      %{
        resource_type: "project",
        resource_uuid: Ecto.UUID.generate(),
        endpoint_uuid: Ecto.UUID.generate(),
        prompt_uuid: Ecto.UUID.generate(),
        source_lang: "en",
        target_lang: "es"
      },
      overrides
    )
  end

  describe "enqueue/1 — argument validation" do
    test "rejects missing keys with {:invalid, [keys]}" do
      assert {:error, {:invalid, missing}} =
               Translations.enqueue(%{
                 resource_type: "project",
                 resource_uuid: Ecto.UUID.generate(),
                 endpoint_uuid: Ecto.UUID.generate()
                 # missing: prompt_uuid, source_lang, target_lang
               })

      assert :prompt_uuid in missing
      assert :source_lang in missing
      assert :target_lang in missing
    end

    test "rejects blank values" do
      assert {:error, {:invalid, missing}} =
               Translations.enqueue(valid_params(%{resource_uuid: "  "}))

      assert :resource_uuid in missing
    end

    test "rejects non-UUID endpoint/prompt/resource UUIDs" do
      assert {:error, {:invalid_uuids, bad}} =
               Translations.enqueue(valid_params(%{endpoint_uuid: "not-a-uuid"}))

      assert :endpoint_uuid in bad

      assert {:error, {:invalid_uuids, bad}} =
               Translations.enqueue(valid_params(%{prompt_uuid: "garbage"}))

      assert :prompt_uuid in bad

      assert {:error, {:invalid_uuids, bad}} =
               Translations.enqueue(valid_params(%{resource_uuid: "still-bad"}))

      assert :resource_uuid in bad
    end

    test "rejects invalid resource_type" do
      assert {:error, {:invalid_resource_type, "nonsense"}} =
               Translations.enqueue(valid_params(%{resource_type: "nonsense"}))
    end

    test "accepts all four documented resource types (validation gate passes)" do
      # The validation gate's contract is: bad types → `{:error, _}`
      # before any Oban call; good types → proceed to enqueue. The test
      # repo doesn't run Oban, so the actual `Oban.insert/2` call after
      # validation either succeeds (if Oban is up) or raises (if not).
      # We only care that validation doesn't reject the type — wrap
      # the call so an Oban-side raise doesn't fail the test.
      for type <- ~w(project template task assignment) do
        result =
          try do
            Translations.enqueue(valid_params(%{resource_type: type}))
          rescue
            _ -> :oban_not_configured
          end

        refute match?({:error, {:invalid_resource_type, _}}, result),
               "validation rejected type #{type}"

        refute match?({:error, {:invalid, _}}, result),
               "validation rejected required-keys for type #{type}"

        refute match?({:error, {:invalid_uuids, _}}, result),
               "validation rejected UUID shape for type #{type}"
      end
    end
  end

  describe "weird-input handling — fail closed instead of FunctionClauseError" do
    test "enqueue/1 with non-map returns structured error" do
      assert {:error, {:invalid, :not_a_map}} = Translations.enqueue(nil)
      assert {:error, {:invalid, :not_a_map}} = Translations.enqueue("not a map")
      assert {:error, {:invalid, :not_a_map}} = Translations.enqueue([])
      assert {:error, {:invalid, :not_a_map}} = Translations.enqueue(:atom)
    end

    test "enqueue_all_missing/2 with non-map base_params returns structured error" do
      assert {:error, {:invalid, :bad_arguments}} =
               Translations.enqueue_all_missing(nil, ["es"])

      assert {:error, {:invalid, :bad_arguments}} =
               Translations.enqueue_all_missing("not a map", ["es"])
    end

    test "enqueue_all_missing/2 with non-list missing_langs returns structured error" do
      assert {:error, {:invalid, :bad_arguments}} =
               Translations.enqueue_all_missing(valid_params(), "es")

      assert {:error, {:invalid, :bad_arguments}} =
               Translations.enqueue_all_missing(valid_params(), nil)
    end
  end

  describe "AI plugin presence checks — graceful degradation when PhoenixKitAI is absent" do
    # In the test env the `:phoenix_kit_ai` dep IS pulled in by the
    # parent app, but the plugin is not enabled at runtime (no AI
    # endpoints configured in test seed). The helpers should all
    # return safe defaults rather than raising.
    test "ai_translation_available?/0 returns false when no endpoints configured" do
      # Without a seeded `phoenix_kit_ai_endpoints` row enabled, the
      # final `list_ai_endpoints() != []` check fails → false.
      refute Translations.ai_translation_available?()
    end

    test "list_ai_endpoints/0 returns [] when AI not configured" do
      assert Translations.list_ai_endpoints() == []
    end

    test "list_ai_prompts/0 returns [] when AI not configured" do
      assert Translations.list_ai_prompts() == []
    end

    test "get_default_ai_endpoint_uuid/0 returns nil when setting unset" do
      # Default Settings table has no `projects_translation_endpoint_uuid`.
      assert Translations.get_default_ai_endpoint_uuid() in [nil]
    end

    test "get_default_ai_prompt_uuid/0 falls back to slug lookup, returns nil when nothing wired" do
      # No setting, no `translate-projects-content` prompt seeded →
      # `fallback_prompt_uuid/0` returns nil via the
      # `PhoenixKitAI.get_prompt_by_slug/1` shim.
      assert Translations.get_default_ai_prompt_uuid() in [nil]
    end

    test "default_translation_prompt_exists?/0 returns false when no prompt seeded" do
      refute Translations.default_translation_prompt_exists?()
    end
  end

  describe "enqueue_all_missing/2" do
    test "rejects when base params are incomplete" do
      assert {:error, {:invalid, _}} =
               Translations.enqueue_all_missing(
                 %{resource_type: "project"},
                 ["es", "de"]
               )
    end

    test "accepts empty missing list" do
      params = valid_params() |> Map.delete(:target_lang)

      assert {:ok, %{enqueued: 0, conflicts: 0, errors: [], in_flight: []}} =
               Translations.enqueue_all_missing(params, [])
    end
  end
end
