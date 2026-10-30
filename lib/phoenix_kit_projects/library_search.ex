defmodule PhoenixKitProjects.LibrarySearch do
  @moduledoc """
  The task library searched as a title is typed — the suggestions under a
  new task's title (the card list's draft row; the add-task popup can ask
  the same).

  Only the reusable library: a project's one-off tasks (`ad_hoc`) belong to
  that project, and another project's titles must not surface here (Max,
  2026-10-31: "we shouldn't do cross-project stuff. The library being a
  source is good enough").
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Schemas.Task

  require Logger

  @default_limit 6
  @min_length 2

  @doc """
  Library tasks whose title (in any language) contains `query`, the ones
  that start with it first, then the shorter titles. Fewer than two
  characters ask for nothing (`[]`).

  Options: `:limit` (default #{@default_limit}), `:exclude` — task uuids to
  leave out.
  """
  @spec suggest(String.t() | nil, keyword()) :: [Task.t()]
  def suggest(query, opts \\ [])

  def suggest(query, opts) when is_binary(query) do
    q = query |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(q) < @min_length do
      []
    else
      run(q, Keyword.get(opts, :limit, @default_limit), List.wrap(Keyword.get(opts, :exclude)))
    end
  end

  def suggest(_query, _opts), do: []

  defp run(q, limit, exclude) do
    escaped = escape_like(q)
    contains = "%" <> escaped <> "%"
    prefix = escaped <> "%"

    from(t in Task,
      where: t.ad_hoc == false,
      where:
        ilike(t.title, ^contains) or
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_each(?) AS tr WHERE tr.value->>'title' ILIKE ?)",
            t.translations,
            ^contains
          ),
      order_by: [
        asc: fragment("CASE WHEN ? ILIKE ? THEN 0 ELSE 1 END", t.title, ^prefix),
        asc: fragment("length(?)", t.title),
        asc: t.title
      ],
      limit: ^limit
    )
    |> exclude_uuids(exclude)
    |> RepoHelper.repo().all()
  rescue
    e ->
      # Suggestions are a help, never a reason for the title box to fail.
      Logger.warning("[Projects.LibrarySearch] suggest failed: #{Exception.message(e)}")
      []
  end

  defp exclude_uuids(query, []), do: query
  defp exclude_uuids(query, uuids), do: where(query, [t], t.uuid not in ^uuids)

  defp escape_like(q) do
    q
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
