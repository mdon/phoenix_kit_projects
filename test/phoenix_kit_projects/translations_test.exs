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
