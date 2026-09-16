defmodule PhoenixKitProjects.MediaReorganizer do
  @moduledoc """
  Projects' media-reorganizer plan source.

  Not compiled against a core `PhoenixKit.Modules.Storage.Reorganizer.Source`
  behaviour — today's hex core (2.23.x) does not ship the engine yet. This
  module declares no `@behaviour` and returns plain maps; see
  `PhoenixKitProjects.media_reorganizer/0` for the registration comment.
  Once core ships the engine, `plan/2`'s contract (`plan(actor_uuid, opts)
  :: [map()]`) already matches `Source.plan/2` — the only follow-up is
  adding `@behaviour`/`@impl`.

  Covers `Project` only — its legacy `project-<uuid>` folder and the
  `:attachments_parent_folder` / `:attachments_folder_name` hooks
  (`PhoenixKitProjects.Attachments`). Three things this module does NOT
  cover, deliberately:

    * **No pointer to back-fill.** Unlike catalogue, a project carries no
      cached folder uuid (no `data`/JSONB column for it) — its folder is
      always resolved by name, on every read
      (`Attachments.find_resource_folder/2`). So a `:move` action here
      never carries an `after_move`, and a taken destination name is
      `:report`ed rather than `:suffix`ed — renaming the winner would
      strand this module's own lookup, which never searches for a
      suffixed name.
    * **No pending-upload-folder prefix.** `Attachments` never stages an
      upload before the project exists (unlike catalogue's
      `catalogue-attachment-pending-*`), so `plan/2` never emits a
      `:pending` action.
    * **`Portal`/`PortalSubmission` are not a separate resource.** A
      submission's stored attachment is placed under
      `<project folder>/Portal submissions/`
      (`Portal.store_attachments/2` → `Attachments.ensure_folder/2` for
      the *project*), never in a folder of its own — moving the project's
      folder carries that nested subfolder with it for free. Neither
      `Portal` nor `PortalSubmission` ever creates a top-level legacy
      folder, so they get no `plan/2` entries of their own.

  A host that has not configured `:attachments_parent_folder` is left
  entirely untouched: `plan/2`'s move-planning half runs, and the hooks
  are called, only when the env is set to a `{mod, fun}` that is actually
  callable (T3/U7/V3 — a *configured but uncallable* hook, parent OR name,
  e.g. a typo, is a distinct `kind: :hook_error` failure, never silently
  "no hook") — never a single move or report for a legacy folder sitting
  somewhere other than root (see "Move planning"). The orphan scan is
  independent of the hook and always runs (root-only when no parent is
  resolved); it is a `:report`, so it is produced with or without a
  configured hook (E1 — a source with no working hook still emits
  report-only housekeeping, never a `:move`/`:trash`). U4: the orphan
  scan's parent scope is every parent a candidate's parent hook
  successfully resolved, whatever that candidate's own outcome — even one
  later dropped for a failing name hook still contributes its parent.

  ## Move planning

  For each live project (D4 — **archived is live**; only a hard-deleted
  project, i.e. no matching row at all, makes an orphan):

  1. A project is a *candidate* when it has a live folder anywhere named
     after its legacy deterministic name (`project-<uuid>`, resolved
     without calling any hook — one batched query for the whole plan). A
     project with nothing named after it is left alone: nothing exists to
     move, and the host's hooks are never called for it. Candidate
     *detection* is light-selected (only folder names, one query), but
     the record reaching a host hook is always the FULL `Project` row —
     loaded for candidates only, in one batched `where uuid in
     ^candidate_uuids` query (R9 amended).
  2. Only for candidates, the parent hook runs once, called directly and
     guarded (T1: any answer is cast through `Ecto.UUID.cast/1` and
     downcased — never a raw string forwarded into a later query) against
     raising/exiting/returning anything but `{:ok, uuid}` or an explicit
     `nil` (R2): a hook FAILURE skips the project (no move planned for it,
     never treated as "root") and is counted into one `kind: :hook_error`
     report for the whole plan; only an explicit `nil` means root. The
     name hook (`:attachments_folder_name`) is called directly too — but
     ONLY when the parent hook resolved a real parent (R8/T9): when it
     resolves `nil`, `find_resource_folder/2` only ever looks for a host
     name *under a parent*, so without one the desired name stays the
     deterministic `project-<uuid>` name and the (possibly writing or
     expensive) name hook is skipped entirely for that project. Called, a
     failing name hook is a hook FAILURE too (F3, folded into the same
     `kind: :hook_error` count) — never a silent fallback to the
     deterministic name (unlike `Attachments.folder_name/2`, which the
     live UI relies on staying up even when a hook regresses).
  3. The candidate's *current* folder is looked up, in the module's own
     order, only at the resolved parent (host name, then deterministic
     name) and at root (deterministic name) — never the unrestricted
     "anywhere" scan `find_resource_folder/2` falls back to for a live
     upload; this is also why a `nil` parent-hook answer can never move a
     folder that actually lives under a real parent to root (F1) — that
     tier is simply never searched when the resolved parent is root.
     Instead, when exactly one live legacy-named folder exists anywhere and
     it sits under a real parent, it is recognized as the project's current
     folder, left untouched (no move, no rename), and counted once into an
     aggregate `kind: :hook_nil` report for the whole plan — mirroring
     catalogue's `apply_nil_root_guard/1` — rather than the generic
     `:relocated` a stray copy would get. Every OTHER legacy-named folder
     that exists live somewhere other than the project's resolved current
     folder (the owner moved it, it is parked under a parent the project
     was since unlinked from, or it is a leftover twin) is reported
     `kind: :relocated`, never moved — one report per copy, all of them
     (F5) — the parent hook can be actor-dependent, so the reason notes
     that a different actor's hook may still resolve it (E6), and it also
     names the copy's actual place (U3) — at the media root, already a
     twin under the target parent, or under a named third-party parent
     (the only one of the three this module's restricted lookup can
     actually produce, since a copy at root or under the target is always
     caught by `root_match`/`det_parent_match` first — see
     `relocated_reason/3`).
  4. A live match at more than one of these tiers (host-named-under-parent,
     deterministic-named-under-parent, deterministic-named-at-root) is
     unresolvable — reported as `kind: :duplicate`, nothing moved, naming
     every folder found. Two (or more) projects whose current folder
     resolves to the very same live folder (e.g. two projects sharing a
     parent and a colliding host name) are likewise reported as
     `kind: :duplicate`, no move for either.
  5. Two (or more) projects whose *desired* destination coincides (the
     same resolved parent and the same desired name) even though their
     *current* folders differ are reported `kind: :duplicate` instead of
     both being planned as moves — the second move would collide with the
     first at apply time (R7).
  """

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.Modules.Storage.{Folder, FolderLink}
  alias PhoenixKitProjects.Attachments
  alias PhoenixKitProjects.Schemas.Project

  @legacy_prefix "project-"

  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @doc """
  Builds the projects' reorganizer plan: one `:move` action per project
  whose current folder does not already match its hooks, `:report`
  actions (`kind: :duplicate` / `kind: :relocated`) for folders that
  cannot be unambiguously resolved or moved, and a `:report`
  (`kind: :orphan`) per legacy `project-<uuid>` folder whose project no
  longer exists.

  `opts` is accepted for interface parity with other Sources (e.g. the
  shared `pending_days` convention) but unused — this module has no
  pending-folder rule.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, _opts \\ []) do
    {resource_actions, resolved_parents, claimed_uuids} = resource_plan(actor_uuid)

    resource_actions ++ orphan_actions(resolved_parents, claimed_uuids)
  end

  # ── Projects ─────────────────────────────────────────────────────

  defp resource_plan(actor_uuid) do
    case hook_status() do
      :ok ->
        build_resource_plan(actor_uuid)

      {:not_callable, config} ->
        {[not_callable_hook_action(config)], [], claimed_folder_uuids([], [], [], [])}

      :none ->
        {[], [], claimed_folder_uuids([], [], [], [])}
    end
  end

  # T3: a configured `{mod, fun}` that is not actually callable (a typo, a
  # removed function) is a distinct failure from "no hook configured at
  # all" — it must not silently degrade to report-only (E1) without telling
  # the owner why nothing moved. V3/U7: ANY configured value that is not a
  # `{mod, fun}` naming a callable function — a typo'd tuple or outright
  # garbage (a string, an integer, a wrong-arity tuple, a tuple of
  # non-atoms) — is the very same misconfiguration and gets the very same
  # `:hook_error`; only a genuinely unset key (`nil`, the default) means
  # "no hook".
  defp hook_status do
    case Application.get_env(:phoenix_kit_projects, :attachments_parent_folder) do
      nil ->
        :none

      {mod, fun} = config when is_atom(mod) and is_atom(fun) ->
        if callable?(mod, fun), do: :ok, else: {:not_callable, config}

      other ->
        {:not_callable, other}
    end
  end

  defp callable?(mod, fun) do
    Code.ensure_loaded?(mod) and
      (function_exported?(mod, fun, 3) or function_exported?(mod, fun, 2))
  end

  defp not_callable_hook_action(config) do
    %{
      source: "projects",
      kind: :hook_error,
      op: :report,
      label: "attachments parent hook",
      counts: nil,
      reason:
        "configured parent hook #{inspect(config)} is not callable or not a valid " <>
          "{module, function} config"
    }
  end

  # Candidate detection needs no hook call: a live folder anywhere named
  # after the project's legacy name (one batched query for the whole
  # plan). Only candidates go on to have the host's parent/name hooks
  # resolved — a project with nothing pointing at it never triggers a
  # (possibly writing) host hook. See moduledoc "Move planning".
  defp build_resource_plan(actor_uuid) do
    candidate_uuids = candidate_project_uuids()
    candidates = full_candidate_projects(candidate_uuids)

    {mod, fun} = Application.get_env(:phoenix_kit_projects, :attachments_parent_folder)

    {desired, hook_error_labels, resolved_parents} =
      resolve_desired(candidates, mod, fun, actor_uuid)

    # R10/T6: `order_index` pins the light query's deterministic order
    # (`inserted_at`/`uuid`) so it survives `split_shared`/`split_converging`
    # below, which regroup entries by folder/destination — a plain
    # `group_by` + `Map.values/1` does not promise to hand groups back in
    # the order their keys were first seen.
    desired =
      desired |> Enum.with_index() |> Enum.map(fn {d, idx} -> Map.put(d, :order_index, idx) end)

    by_parent_host = preload_pairs(desired, & &1.name)
    by_parent_deterministic = preload_pairs(desired, & &1.deterministic_name)
    by_root = preload_by_root_name(Enum.map(desired, & &1.deterministic_name))
    by_anywhere = preload_by_anywhere_name(Enum.map(desired, & &1.deterministic_name))

    entries =
      Enum.map(
        desired,
        &resolve_entry(&1, by_parent_host, by_parent_deterministic, by_root, by_anywhere)
      )

    hook_nil_labels = entries |> Enum.filter(& &1.hook_nil) |> Enum.map(& &1.project.name)

    # R10/T6: entries keep the light query's deterministic order
    # (`inserted_at`/`uuid`) all the way through — split below with
    # `Enum.split_with`/`Enum.reject`, which preserve list order, never a
    # plain `group_by`+reduce (that scrambles it via map iteration order).
    {ambiguous, normal} = Enum.split_with(entries, & &1.ambiguous)
    {with_folder, without_folder} = Enum.split_with(normal, & &1.folder)

    {shared, unique} = split_shared(with_folder)

    # U2/F6: convergence collisions are only meaningful among entries that
    # actually need to move — a folder already sitting exactly where it
    # belongs (`noop_move?`) can never collide with anything at apply
    # time, so it must never be swept into a `:duplicate` report merely
    # for sharing its resolved destination with a real mover. Mirrors
    # manufacturing's noop-then-converging ordering.
    {movers, _noops} =
      Enum.split_with(unique, &(!noop_move?(&1.folder, &1.parent_uuid, &1.name)))

    {converging, _solo_movers} = split_converging(movers)

    claimed_uuids = claimed_folder_uuids(unique, ambiguous, shared, converging)

    # F5/T5: every live legacy-named copy other than the project's adopted
    # current folder (if any) gets its own `:relocated` report — all of
    # them, not only the first — except a copy that is itself another
    # project's claimed (adopted) folder, which is never also reported as
    # relocated. Mirrors catalogue's `stray_legacy` handling.
    stray_actions = stray_relocated_actions(with_folder ++ without_folder, claimed_uuids)

    converging_project_uuids = converging |> List.flatten() |> MapSet.new(& &1.project.uuid)

    move_actions =
      unique
      |> Enum.reject(&MapSet.member?(converging_project_uuids, &1.project.uuid))
      |> Enum.map(&build_move_action/1)
      |> Enum.reject(&is_nil/1)

    dup_actions = Enum.map(ambiguous, &build_ambiguous_duplicate_action/1)
    shared_actions = Enum.map(shared, &build_shared_duplicate_action/1)
    converging_actions = Enum.map(converging, &build_converging_duplicate_action/1)
    hook_error_actions = hook_error_action(hook_error_labels)
    hook_nil_actions = hook_nil_action(hook_nil_labels)

    actions =
      finalize_counts(move_actions ++ stray_actions) ++
        dup_actions ++
        shared_actions ++ converging_actions ++ hook_error_actions ++ hook_nil_actions

    {actions, resolved_parents, claimed_uuids}
  end

  # F5/T5: a live legacy-named copy of a project other than its adopted
  # current folder — one `:relocated` report per copy, all of them, never
  # just the first. A copy that is itself claimed by another project (its
  # own resolved current folder) is excluded — a claimed folder is never
  # also reported `:relocated`. U3: batched over the whole plan so naming
  # a stray copy's actual (third-party) parent for the report never costs
  # a query per copy.
  defp stray_relocated_actions(entries, claimed) do
    pairs =
      Enum.flat_map(entries, fn entry ->
        entry.stray_legacy
        |> Enum.reject(&MapSet.member?(claimed, &1.uuid))
        |> Enum.map(&{entry, &1})
      end)

    parent_names = load_stray_parent_names(pairs)

    Enum.map(pairs, fn {entry, folder} ->
      build_relocated_action(entry.project, folder, entry.parent_uuid, parent_names)
    end)
  end

  # Only a stray copy's parent that is neither root nor the project's own
  # target needs a name — those two cases have their own wording below.
  defp load_stray_parent_names(pairs) do
    uuids =
      pairs
      |> Enum.map(fn {entry, folder} -> other_parent_uuid(folder, entry.parent_uuid) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case uuids do
      [] ->
        %{}

      uuids ->
        Folder
        |> where([f], f.uuid in ^uuids)
        |> select([f], {f.uuid, f.name})
        |> repo().all()
        |> Map.new()
    end
  end

  defp other_parent_uuid(%Folder{parent_uuid: nil}, _target_parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, _target_parent_uuid), do: parent_uuid

  # Order-preserving split into `unique` (one project ↔ one folder) and
  # `shared` groups (X5 — two or more projects resolve to the very same
  # live folder) — a plain `group_by`+reduce over `with_folder` would
  # scramble R10's enumeration order via map iteration order.
  defp split_shared(entries) do
    freq = Enum.frequencies_by(entries, & &1.folder.uuid)
    {shared_entries, unique} = Enum.split_with(entries, &(Map.get(freq, &1.folder.uuid) > 1))
    shared_groups = shared_entries |> group_by_ordered(& &1.folder.uuid)
    {shared_groups, unique}
  end

  # R2: resolves each candidate's parent via the host's own hook, called
  # directly (never through `Attachments.parent_folder_uuid/2`, which
  # swallows a raise/bad-return into `nil` and would make a hook FAILURE
  # indistinguishable from an explicit "root"). A failure skips the
  # project entirely (no move planned) and is tallied into one
  # `hook_error_count` for the whole plan instead. R8/T9: the name hook is
  # only called when a parent WAS resolved — `find_resource_folder/2` only
  # ever looks for a host name *under a parent*, so a project whose parent
  # resolves to root keeps the deterministic name, and the (possibly
  # writing/expensive) name hook is never called for it. F3: a name hook
  # that itself raises or returns garbage is a hook FAILURE too, not a
  # silent fallback to the deterministic name.
  # U4: `resolved_parents` (the orphan scan's scope) is collected here from
  # every SUCCESSFUL parent-hook answer, independent of what happens to
  # that candidate afterwards — even a project later dropped for a failing
  # name hook still contributes the parent its own parent hook resolved,
  # so an orphan sitting under that same parent is not lost from the scan.
  defp resolve_desired(candidates, mod, fun, actor_uuid) do
    {desired, error_labels, parent_uuids} =
      Enum.reduce(candidates, {[], [], MapSet.new()}, fn project, {acc, errs, parents} ->
        case resolve_parent(mod, fun, :project, actor_uuid, project) do
          {:ok, nil} ->
            push_desired(project, nil, actor_uuid, acc, errs, parents)

          {:ok, parent_uuid} ->
            push_desired(
              project,
              parent_uuid,
              actor_uuid,
              acc,
              errs,
              MapSet.put(parents, parent_uuid)
            )

          :error ->
            {acc, [project.name | errs], parents}
        end
      end)

    {Enum.reverse(desired), Enum.reverse(error_labels), MapSet.to_list(parent_uuids)}
  end

  defp push_desired(project, nil, _actor_uuid, acc, errs, parents) do
    deterministic_name = Attachments.folder_name(project.uuid)

    entry = %{
      project: project,
      parent_uuid: nil,
      name: deterministic_name,
      deterministic_name: deterministic_name
    }

    {[entry | acc], errs, parents}
  end

  defp push_desired(project, parent_uuid, actor_uuid, acc, errs, parents) do
    deterministic_name = Attachments.folder_name(project.uuid)

    case resolve_folder_name(project, actor_uuid) do
      {:ok, name} ->
        entry = %{
          project: project,
          parent_uuid: parent_uuid,
          name: name,
          deterministic_name: deterministic_name
        }

        {[entry | acc], errs, parents}

      :error ->
        {acc, [project.name | errs], parents}
    end
  end

  defp resolve_parent(mod, fun, kind, actor_uuid, resource) do
    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 3) ->
        guarded_hook_call(mod, fun, kind, fn -> apply(mod, fun, [kind, actor_uuid, resource]) end)

      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) ->
        guarded_hook_call(mod, fun, kind, fn -> apply(mod, fun, [kind, actor_uuid]) end)

      true ->
        :error
    end
  end

  # T1: every answer is cast through `Ecto.UUID.cast/1` and downcased —
  # `{:ok, ""}` / `{:ok, "not-a-uuid"}` are hook FAILURES (`:error`), never
  # sent into a later `in ^uuids`/`==` query (which would raise a
  # `Ecto.Query.CastError` and take down the whole plan). F2: an explicit
  # `{:ok, nil}` or bare `nil` means root. U6: every failure — a raise/exit
  # as well as a plain bad return value — is logged with the configured
  # `{mod, fun}` and the resource kind, so an owner can find the culprit
  # from the log alone.
  defp guarded_hook_call(mod, fun_name, kind, fun) do
    case fun.() do
      {:ok, uuid} when is_binary(uuid) ->
        case Ecto.UUID.cast(uuid) do
          {:ok, cast} -> {:ok, cast}
          :error -> log_bad_parent_hook_return(mod, fun_name, kind, {:ok, uuid})
        end

      {:ok, nil} ->
        {:ok, nil}

      nil ->
        {:ok, nil}

      other ->
        log_bad_parent_hook_return(mod, fun_name, kind, other)
    end
  rescue
    error ->
      Logger.warning(
        "Attachments parent hook #{inspect(mod)}.#{fun_name} (#{kind}) raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  catch
    kind2, reason ->
      Logger.warning(
        "Attachments parent hook #{inspect(mod)}.#{fun_name} (#{kind}) #{kind2}: #{inspect(reason)}"
      )

      :error
  end

  defp log_bad_parent_hook_return(mod, fun_name, kind, value) do
    Logger.warning(
      "Attachments parent hook #{inspect(mod)}.#{fun_name} (#{kind}): bad return #{inspect(value)}"
    )

    :error
  end

  # F3: the (optional) `:attachments_folder_name` hook, called directly
  # (not through `Attachments.folder_name/2`, which is deliberately
  # defensive for the live UI and swallows a failing hook into the
  # deterministic name) so a raising/garbage-returning hook is a
  # reportable failure here instead of a silent fallback. Not configured
  # at all is NOT a failure — it is simply "no host name", same as
  # `Attachments.folder_name/2` treats it. U7/V3: configured but not a
  # `{mod, fun}` shape at all (a string, an integer, a wrong-arity tuple, a
  # tuple of non-atoms), or a `{mod, fun}` that is not actually callable,
  # are BOTH the same failure — the same misconfiguration the parent hook
  # already reports as `:hook_error` — never a silent fallback to the
  # deterministic name either.
  defp resolve_folder_name(project, actor_uuid) do
    case Application.get_env(:phoenix_kit_projects, :attachments_folder_name) do
      nil ->
        {:ok, Attachments.folder_name(project.uuid)}

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        resolve_configured_folder_name(mod, fun, project, actor_uuid)

      _other ->
        :error
    end
  end

  defp resolve_configured_folder_name(mod, fun, project, actor_uuid) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) do
      case guarded_name_hook_call(mod, fun, project, actor_uuid) do
        {:ok, nil} -> {:ok, Attachments.folder_name(project.uuid)}
        {:ok, name} -> {:ok, name}
        :error -> :error
      end
    else
      :error
    end
  end

  # U6: a plain bad return (not a raise/exit) is logged too, with the
  # configured `{mod, fun}` — previously only the rescue/catch clauses did.
  defp guarded_name_hook_call(mod, fun, project, actor_uuid) do
    case apply(mod, fun, [project, actor_uuid]) do
      {:ok, name} when is_binary(name) and name != "" ->
        {:ok, name}

      nil ->
        {:ok, nil}

      other ->
        Logger.warning(
          "Attachments name hook #{inspect(mod)}.#{fun} (project): bad return #{inspect(other)}"
        )

        :error
    end
  rescue
    error ->
      Logger.warning(
        "Attachments name hook #{inspect(mod)}.#{fun} (project) raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  catch
    kind, reason ->
      Logger.warning(
        "Attachments name hook #{inspect(mod)}.#{fun} (project) #{kind}: #{inspect(reason)}"
      )

      :error
  end

  defp hook_nil_action([]), do: []

  defp hook_nil_action(labels) do
    [
      %{
        source: "projects",
        kind: :hook_nil,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{length(labels)} record(s): the parent hook answered root for a folder living " <>
            "under a parent — left in place — #{label_list(labels)}"
      }
    ]
  end

  defp hook_error_action([]), do: []

  defp hook_error_action(labels) do
    [
      %{
        source: "projects",
        kind: :hook_error,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{length(labels)} record(s) skipped: the configured parent hook raised, exited, or " <>
            "returned neither {:ok, uuid} nor nil — #{label_list(labels)}"
      }
    ]
  end

  # U8: `:hook_error`/`:hook_nil` reports list the first 10 record labels
  # so the owner can tell where to look, instead of a bare count —
  # "… and N more" for the rest.
  defp label_list(labels) do
    {shown, rest} = Enum.split(labels, 10)

    case rest do
      [] -> Enum.join(shown, ", ")
      _ -> Enum.join(shown, ", ") <> " … and #{length(rest)} more"
    end
  end

  # One batched query for the whole plan: every live folder named after
  # the legacy `project-<uuid>` pattern, anywhere. Only a project whose
  # uuid appears in this set is a candidate — see `build_resource_plan/2`.
  defp candidate_project_uuids do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
    |> select([f], f.name)
    |> repo().all()
    |> Enum.map(&legacy_uuid/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # host-name-under-parent → deterministic-name-under-parent →
  # deterministic-name-at-root — the module's own order, restricted to
  # root and the resolved parent (X9 — unlike
  # `Attachments.find_resource_folder/2`, this never treats an
  # unrestricted "anywhere" hit as the current folder to move; it is only
  # used below to tell a genuinely absent candidate apart from one that is
  # live but relocated). A live match at more than one of these tiers is
  # ambiguous.
  #
  # `by_anywhere` (every live folder anywhere named after the project's
  # legacy name) also surfaces STRAY twins: when a single restricted match
  # IS found, every OTHER live folder sharing the legacy name elsewhere (a
  # third parent, neither root nor the resolved parent) is a separate
  # leftover — never this project's current folder, never an orphan (the
  # project is alive) — kept as `stray_legacy` (F5: every one of them, not
  # only the first) and reported `:relocated` alongside whatever action
  # the project itself gets (see `build_resource_plan/2`). When NO
  # restricted match exists at all, every live "anywhere" match is itself
  # a stray copy — F1: the project's current folder is simply not found
  # this run (a nil-root hook answer never treats one of these as "the"
  # folder to move to root; see the moduledoc and the F1 test).
  defp resolve_entry(d, by_parent_host, by_parent_deterministic, by_root, by_anywhere) do
    host_match = d.parent_uuid && Map.get(by_parent_host, {d.name, d.parent_uuid})

    det_parent_match =
      d.parent_uuid && Map.get(by_parent_deterministic, {d.deterministic_name, d.parent_uuid})

    root_match = Map.get(by_root, d.deterministic_name)

    matches =
      [host_match, det_parent_match, root_match]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.uuid)

    anywhere = Map.get(by_anywhere, d.deterministic_name, [])

    case matches do
      [] ->
        hook_nil_entry(d, anywhere) ||
          Map.merge(d, %{folder: nil, ambiguous: nil, stray_legacy: anywhere, hook_nil: false})

      [folder] ->
        stray = Enum.filter(anywhere, &(&1.uuid != folder.uuid))
        Map.merge(d, %{folder: folder, ambiguous: nil, stray_legacy: stray, hook_nil: false})

      matches ->
        Map.merge(d, %{folder: nil, ambiguous: matches, stray_legacy: [], hook_nil: false})
    end
  end

  # F1: the restricted tiers above never search under a real parent once
  # the hook resolves root (`d.parent_uuid == nil`), which is what keeps a
  # nil answer from ever moving a nested folder to root. When that leaves
  # `matches` empty but exactly one live folder anywhere still carries the
  # project's legacy name AND currently sits under a real parent, that
  # folder IS the project's current folder — left in place (no move, no
  # rename) and counted once into the aggregate `:hook_nil` report instead
  # of the generic `:relocated` a stray copy would get. Mirrors catalogue's
  # `apply_nil_root_guard/1`.
  defp hook_nil_entry(%{parent_uuid: nil} = d, [%Folder{parent_uuid: parent_uuid}])
       when not is_nil(parent_uuid) do
    Map.merge(d, %{folder: nil, ambiguous: nil, stray_legacy: [], hook_nil: true})
  end

  defp hook_nil_entry(_d, _anywhere), do: nil

  # R7/E3: two (or more) `unique` entries whose *desired* target (resolved
  # parent + desired name) coincide, even though their current folders
  # differ — the second move would collide with the first at apply time.
  # Order-preserving (a plain `group_by` would scramble R10's enumeration
  # order).
  defp split_converging(entries) do
    freq = Enum.frequencies_by(entries, &convergence_key/1)

    {converging_entries, solo} =
      Enum.split_with(entries, &(Map.get(freq, convergence_key(&1)) > 1))

    converging_groups = converging_entries |> group_by_ordered(&convergence_key/1)
    {converging_groups, solo}
  end

  defp convergence_key(entry), do: {entry.parent_uuid, entry.name}

  # `Enum.group_by/2` keeps each group's own members in encounter order, but
  # its result is a map — iterating it (`Map.values/1`) is not promised to
  # hand groups back in the order their keys were first seen. Since callers
  # here only ever group entries that already carry `order_index` (R10),
  # sorting the groups by their first (smallest-index) member restores that
  # order deterministically instead of relying on map iteration order.
  defp group_by_ordered(entries, key_fun) do
    entries
    |> Enum.group_by(key_fun)
    |> Map.values()
    |> Enum.sort_by(fn [first | _] -> first.order_index end)
  end

  # R4/§9: every folder this batch has already resolved as a live project's
  # current folder — a unique move/no-op target, every folder listed in an
  # ambiguous match, and every folder claimed by a shared or converging
  # group — must never also be reported `:orphan` below, even when its
  # literal name embeds a different (deleted) project's uuid (e.g. a naive
  # host-name hook that happens to return that stray name). Mirrors
  # catalogue's `claimed_folder_uuids/4`.
  defp claimed_folder_uuids(unique, ambiguous, shared_groups, converging_groups) do
    unique_uuids = Enum.map(unique, & &1.folder.uuid)

    ambiguous_uuids =
      Enum.flat_map(ambiguous, fn %{ambiguous: folders} -> Enum.map(folders, & &1.uuid) end)

    shared_uuids = Enum.flat_map(shared_groups, fn [%{folder: f} | _] -> [f.uuid] end)

    converging_uuids =
      Enum.flat_map(converging_groups, fn group -> Enum.map(group, & &1.folder.uuid) end)

    MapSet.new(unique_uuids ++ ambiguous_uuids ++ shared_uuids ++ converging_uuids)
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or
  # an accepted `"name (N)"` suffix variant) is a no-op — filtered here;
  # (unlike catalogue) this Source never has an `after_move` to keep the
  # action alive for. D3: pointer-less — a taken destination is `:report`ed, never
  # `:suffix`ed (this module's own lookup never searches for a suffixed
  # name, so a renamed winner would be orphaned from its project).
  defp build_move_action(%{
         project: project,
         folder: folder,
         parent_uuid: parent_uuid,
         name: name
       }) do
    if noop_move?(folder, parent_uuid, name) do
      nil
    else
      %{
        source: "projects",
        kind: :project,
        label: project.name,
        op: :move,
        folder: folder,
        parent_uuid: parent_uuid,
        name: name,
        counts: nil,
        on_conflict: :report,
        after_move: nil
      }
    end
  end

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: folder_name}, parent_uuid, name) do
    suffixed_variant?(folder_name, name)
  end

  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp suffixed_variant?(folder_name, name) do
    Regex.match?(~r/\A#{Regex.escape(name)} \(\d+\)\z/, folder_name)
  end

  # E6: the parent hook can be actor-dependent (`fun(kind, actor_uuid,
  # resource)`), so a folder this run's actor can't place is not
  # necessarily unreachable for every actor — the reason says so rather
  # than implying the folder is permanently stuck. U3: the reason also
  # names the copy's actual place (media root / twin under the target
  # parent / under a third-party parent's name) instead of one blanket
  # phrase — for this module's restricted 3-tier lookup (see
  # `resolve_entry/5`) a stray copy is structurally always the third case
  # (root and target-parent copies are always caught by `root_match`/
  # `det_parent_match` instead), but the other two clauses are kept for
  # parity with the other Sources and in case that lookup ever widens.
  defp build_relocated_action(project, folder, target_parent_uuid, parent_names) do
    %{
      source: "projects",
      kind: :relocated,
      label: project.name,
      op: :report,
      folder: folder,
      counts: nil,
      reason: relocated_reason(folder, target_parent_uuid, parent_names)
    }
  end

  defp relocated_reason(%Folder{parent_uuid: nil} = folder, _target_parent_uuid, _names) do
    "legacy folder #{folder.name} (#{folder.uuid}) is live at the media root — left alone " <>
      "(the parent hook may resolve it for other actors); move it manually"
  end

  defp relocated_reason(%Folder{parent_uuid: parent_uuid} = folder, parent_uuid, _names) do
    "legacy folder #{folder.name} (#{folder.uuid}) is already live as a twin under the target " <>
      "parent — left alone (the parent hook may resolve it for other actors); an eventual move " <>
      "there will collide, landing as \"name (N)\""
  end

  defp relocated_reason(%Folder{parent_uuid: parent_uuid} = folder, _target_parent_uuid, names) do
    parent_label = Map.get(names, parent_uuid, parent_uuid)

    "legacy folder #{folder.name} (#{folder.uuid}) is live under #{parent_label} — left alone " <>
      "(the parent hook may resolve it for other actors); move it manually"
  end

  defp build_ambiguous_duplicate_action(%{project: project, ambiguous: folders}) do
    places = Enum.map_join(folders, ", ", & &1.uuid)

    %{
      source: "projects",
      kind: :duplicate,
      label: project.name,
      op: :report,
      counts: nil,
      reason:
        "legacy folder found live in #{length(folders)} places (#{places}) — pick one and " <>
          "remove the rest"
    }
  end

  defp build_shared_duplicate_action([%{folder: folder} | _] = group) do
    labels = group |> Enum.map(& &1.project.name) |> Enum.uniq() |> Enum.join(", ")

    %{
      source: "projects",
      kind: :duplicate,
      label: folder.name,
      op: :report,
      counts: nil,
      reason: "folder #{folder.uuid} is claimed by more than one project: #{labels}"
    }
  end

  defp build_converging_duplicate_action([entry | _] = group) do
    labels = group |> Enum.map(& &1.project.name) |> Enum.uniq() |> Enum.join(", ")
    parent_label = entry.parent_uuid || "root"

    %{
      source: "projects",
      kind: :duplicate,
      label: labels,
      op: :report,
      counts: nil,
      reason:
        "multiple projects would move to the same destination (parent #{parent_label}, " <>
          "name #{entry.name}): #{labels}"
    }
  end

  # One query for every distinct {name, parent_uuid} pair the batch needs —
  # not a query per project. `name_fun` selects `desired.name` (host-name
  # tier) or `desired.deterministic_name` (legacy-name tier); both share
  # this shape. Live folders only (X2 — the unique index is partial, a
  # trashed twin must not hide the live folder).
  defp preload_pairs(desired, name_fun) do
    pairs =
      desired
      |> Enum.map(&{name_fun.(&1), &1.parent_uuid})
      |> Enum.reject(fn {_name, parent_uuid} -> is_nil(parent_uuid) end)
      |> Enum.uniq()

    names = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    parents = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    if names == [] or parents == [] do
      %{}
    else
      Folder
      |> where([f], f.name in ^names and f.parent_uuid in ^parents and is_nil(f.trashed_at))
      |> repo().all()
      |> Map.new(&{{&1.name, &1.parent_uuid}, &1})
    end
  end

  # One query for every distinct deterministic name in the batch, at root.
  # Live only (X2).
  defp preload_by_root_name(names) do
    case names |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.parent_uuid) and is_nil(f.trashed_at))
        |> repo().all()
        |> Map.new(&{&1.name, &1})
    end
  end

  # One query for every distinct deterministic name in the batch, live,
  # regardless of parent, grouped by name (oldest first per group,
  # mirroring `Attachments.find_folder_anywhere/1`'s
  # `order_by: [asc: :inserted_at]`) — batched instead of one query per
  # name. Used to detect a relocated candidate when no restricted match
  # exists at all (X9 — the first/oldest of the group), and to detect a
  # stray legacy-named twin when a restricted match WAS found (any other
  # live folder in the group, `resolve_entry/5`) — never as a match a
  # `:move` is planned for.
  defp preload_by_anywhere_name(names) do
    case names |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.trashed_at))
        |> order_by([f], asc: f.inserted_at)
        |> repo().all()
        |> Enum.group_by(& &1.name)
    end
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`project-<uuid>`) at the media root or under a
  # parent this batch's hooks resolved to, whose uuid no longer names any
  # project row (D4 — a hard delete is the only way a project stops
  # existing; archived projects are live) is reported so a host can
  # collect it. Never `:move`d or `:trash`ed here — this module owns no
  # "orphans" container; a legacy folder claimed by a live project (its
  # current folder, a duplicate, or a converging-target group) is excluded
  # (R4 — one folder gets at most one action).
  defp orphan_actions(resolved_parents, claimed_uuids) do
    case legacy_candidate_folders(resolved_parents, claimed_uuids) do
      [] ->
        []

      candidates ->
        existing_uuids = load_candidate_records(candidates)
        counts = counts_by_folder(Enum.map(candidates, fn {folder, _uuid} -> folder.uuid end))

        candidates
        |> Enum.map(&orphan_action(&1, existing_uuids, counts))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One SQL-filtered query (X6 — prefix filter in SQL, not loaded then
  # filtered in Elixir) for every live folder at root or under a resolved
  # parent whose name starts with the legacy prefix, minus every folder
  # already claimed by a live project (R4 — see `claimed_folder_uuids/4`).
  # R10/T6: ordered deterministically, same as the candidate queries.
  defp legacy_candidate_folders(parent_uuids, claimed_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
    |> order_by([f], asc: f.inserted_at, asc: f.uuid)
    |> repo().all()
    |> Enum.reject(&MapSet.member?(claimed_uuids, &1.uuid))
    |> Enum.map(&{&1, legacy_uuid(&1.name)})
    |> Enum.filter(fn {_folder, uuid} -> uuid end)
  end

  # X7: a strict UUID regex on the suffix (36-char canonical form) — not
  # `Ecto.UUID.cast/1`, which also accepts a raw 16-byte binary and, kept
  # verbatim rather than the cast's normalised value, an uppercase suffix
  # that would never match the (lowercase) record uuid it belongs to.
  defp legacy_uuid(name) do
    suffix = String.replace_prefix(name, @legacy_prefix, "")

    if Regex.match?(@uuid_regex, suffix) do
      String.downcase(suffix)
    end
  end

  # One query for every candidate uuid in the batch — not per folder. Always
  # called with a non-empty list (the caller branches on `[]` already).
  # R9: only the uuid column — an orphan report needs nothing else off the
  # record (existence alone decides it).
  defp load_candidate_records(candidates) do
    uuids = candidates |> Enum.map(fn {_folder, uuid} -> uuid end) |> Enum.uniq()

    Project
    |> where([p], p.uuid in ^uuids)
    |> select([p], p.uuid)
    |> repo().all()
    |> MapSet.new()
  end

  defp orphan_action({folder, uuid}, existing_uuids, counts) do
    if MapSet.member?(existing_uuids, uuid) do
      nil
    else
      folder_counts = folder_counts(counts, folder.uuid)

      %{
        source: "projects",
        kind: :orphan,
        op: :report,
        label: folder.name,
        folder: folder,
        counts: folder_counts,
        reason: "record missing, #{elem(folder_counts, 0)} file(s)"
      }
    end
  end

  # ── Shared helpers ───────────────────────────────────────────────

  # X1: two grouped queries (files by folder_uuid, links by folder_uuid)
  # per call — never a query per action. Counts ALL rows regardless of
  # status (including trashed files) — the core engine re-measures the
  # same way at apply time (any row with this `folder_uuid`) and aborts
  # the action on a mismatch, so a plan-time count that excluded trashed
  # files would fail every folder holding one.
  defp counts_by_folder(folder_uuids) do
    case Enum.uniq(folder_uuids) do
      [] ->
        {%{}, %{}}

      uuids ->
        files =
          PhoenixKit.Modules.Storage.File
          |> where([f], f.folder_uuid in ^uuids)
          |> group_by([f], f.folder_uuid)
          |> select([f], {f.folder_uuid, count(f.uuid)})
          |> repo().all()
          |> Map.new()

        links =
          FolderLink
          |> where([l], l.folder_uuid in ^uuids)
          |> group_by([l], l.folder_uuid)
          |> select([l], {l.folder_uuid, count(l.uuid)})
          |> repo().all()
          |> Map.new()

        {files, links}
    end
  end

  defp folder_counts({files, links}, folder_uuid) do
    {Map.get(files, folder_uuid, 0), Map.get(links, folder_uuid, 0)}
  end

  # Fills `counts: nil` placeholders left by `build_move_action/1` and
  # `build_relocated_action/1` with a single batched lookup across every
  # folder-bearing action — the whole resource-plan's counts come from one
  # pair of grouped queries (X1), not one pair per action.
  defp finalize_counts(actions) do
    counts =
      actions
      |> Enum.map(fn
        %{folder: %Folder{uuid: uuid}} -> uuid
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> counts_by_folder()

    Enum.map(actions, fn
      %{folder: %Folder{uuid: uuid}} = action -> %{action | counts: folder_counts(counts, uuid)}
      action -> action
    end)
  end

  # R9 (amended): light selects are for candidate detection only — the
  # record reaching ANY host hook (parent, name) must be the FULL row, a
  # host hook is opaque and may read anything off it (Andi's project hook
  # reads assignment/sub-order fields the same way catalogue's reads
  # `parent_uuid`). One batched `where uuid in ^candidate_uuids` query for
  # the whole plan, never a query per project — ordered by
  # `inserted_at`/`uuid` for a deterministic report order (R10).
  defp full_candidate_projects(candidate_uuids) do
    case MapSet.to_list(candidate_uuids) do
      [] ->
        []

      uuids ->
        Project
        |> where([p], p.uuid in ^uuids)
        |> order_by([p], asc: p.inserted_at, asc: p.uuid)
        |> repo().all()
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
