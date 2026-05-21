defmodule PhoenixKitProjects.Web.AITranslateFormHelpers do
  @moduledoc """
  Shared form-LV helpers for the AI translate bar wiring on project,
  template, and task forms.

  Extracted because the three form LVs each held an identical copy of
  these helpers. Beyond dedup, lifting them out makes the
  `merge_blank_fields_only/2` policy directly unit-testable — the
  user-edits-win contract is load-bearing for the form UX (a
  translation that lands mid-edit must not silently clobber what the
  user typed).
  """

  @doc """
  Computes the `missing` list for the language switcher's
  `ai_translate.missing` slot.

  A language is "missing" when it's in the host's enabled-language
  list, isn't the primary language, and doesn't have **any non-blank
  translatable field** for that language code yet.

  The non-blank rule matters: `%{"es" => %{}}` and
  `%{"es" => %{"name" => ""}}` both still count as missing — the
  user hasn't actually translated anything yet, just opened the tab.
  Treating an empty map as "translated" would hide the sparkle the
  user is looking for.
  """
  @spec missing_languages([map()], String.t(), map() | nil, [atom() | String.t()]) ::
          [String.t()]
  def missing_languages(language_tabs, primary_language, translations, translatable_fields) do
    enabled = Enum.map(language_tabs || [], & &1.code)
    have = translations || %{}

    Enum.reject(enabled, fn lang ->
      lang == primary_language or has_any_translation?(have, lang, translatable_fields)
    end)
  end

  @doc """
  Does the resource have at least one non-blank translatable field
  for `lang`?
  """
  @spec has_any_translation?(map(), String.t(), [atom() | String.t()]) :: boolean()
  def has_any_translation?(translations, lang, translatable_fields) do
    case Map.get(translations, lang) do
      m when is_map(m) ->
        Enum.any?(translatable_fields, fn field ->
          case Map.get(m, field) do
            v when is_binary(v) -> String.trim(v) != ""
            _ -> false
          end
        end)

      _ ->
        false
    end
  end

  @doc """
  Merges the AI's translated `new_lang_map` into the existing
  `current_lang_map`, with **user-typed values winning over AI
  output**.

  A field is updated by the AI only when the current value is
  blank (`nil`, `""`, or whitespace-only). If the user switched to
  the target language during the Oban job and typed something in
  e.g. `name`, the AI's translated name will NOT overwrite it.

  This is the policy fix from PR #12's final codex review — an
  unconditional `Map.merge/2` would silently clobber edits the user
  made between dispatching the translation and the job completing.
  """
  @spec merge_blank_fields_only(map(), map()) :: map()
  def merge_blank_fields_only(current_lang_map, new_lang_map)
      when is_map(current_lang_map) and is_map(new_lang_map) do
    Enum.reduce(new_lang_map, current_lang_map, fn {field, ai_value}, acc ->
      if blank?(Map.get(acc, field)) do
        Map.put(acc, field, ai_value)
      else
        acc
      end
    end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false
end
