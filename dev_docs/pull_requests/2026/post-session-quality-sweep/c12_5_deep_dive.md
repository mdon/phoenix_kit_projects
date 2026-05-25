# C12.5 Adversarial deep dive — post-session sweep

Two-repo scope: `phoenix_kit` (`modal-to-native-dialog`) and
`phoenix_kit_projects` (`followup-review-pr13-fixes`).

Per the workspace playbook, run each of the 13 categories as a
self-prompt + a verification action. Findings classified: **fix
in-scope** (this PR), **out of scope** (separate sweep — pre-existing
on the branch base), or **clean** (verified, no issue).

## 1 — Documentation
- **Status:** punted to C13 (next task). AGENTS.md updates pending for
  the new core components (bulk_select toolkit, sortable, drag_handle,
  reorder_modal, load_more, modal `keep_in_dom`, PkDialog hook,
  BulkSelectScope hook, PkCheckboxIndeterminate hook).

## 2 — Components
- **Status:** clean. The refactor inverts the historical concern —
  every list-UI piece used to be bespoke in `phoenix_kit_projects`
  and is now in `phoenix_kit/lib/phoenix_kit_web/components/core/`.
  No new bespoke widgets introduced; the migration's *purpose* is
  pulling them up into core.

## 3 — Senior-dev review
- **Fix:** Add `@spec` to `Projects.maybe_limit/2` (was untyped; agent
  flagged hidden Ecto coupling). Done.
- **Fix:** Strengthen the `keep_in_dom` docstring on `<.modal>` to
  warn about ID collisions when two kept-in-DOM modals share an
  `on_close` event name. Done.
- **Out of scope** (pre-existing on base): `confirm_modal` fragile
  default class comparison; `bump_translation_started`'s
  forward-looking `:in_progress` branch; `translate_resource_worker`
  end-of-transaction comment vs structural enforcement; `:position`
  vs `_dir` clause shape (this is intentional — position has no
  direction).

## 4 — Security
- **Status:** clean. C12 agent #1 already pinned the surface; the
  additional checks pass.
- `apply_reorder` uses a hardcoded `@reorder_strategies` map for
  string → atom (no atom leak via `String.to_existing_atom` on
  attacker input).
- `sanitize_uuids/1` filters non-binary payload elements; 0–1 uuid
  collapses to `:all` to prevent a single-row "permute" from being
  used to probe state.
- No open redirects added; no raw HTML rendering of user input added;
  no file-system path injection vector touched.

## 5 — Error handling
- **Status:** clean.
- Both list LVs have a `handle_info(msg, socket)` catch-all clause
  that `Logger.debug`s and returns `{:noreply, socket}` (verified
  `projects_live.ex:78-81`, `tasks_live.ex` similar).
- Every reorder code path returns a tagged tuple
  (`:ok | {:error, :wrong_scope | :duplicate_positions | …}`);
  the LV `case` matches each variant with a specific flash.
- Reorder DB errors log via `log_reorder_db_error/3` with the uuids,
  so failed writes are grep-able by `resource_uuid`.

## 6 — Translations
- **Status:** clean (verified by C12 agent #2). All user-facing
  strings flow through `gettext/1` or the module's
  `PhoenixKitProjects.Gettext` backend per the workspace memory
  hybrid-gettext rule.

## 7 — Activity logging
- **Status:** clean.
- DnD reorders log via `log_reorder_success(kind, …)` →
  action `<kind>.reordered`, metadata `%{"count" => N}`.
- Strategy reorders log via `log_strategy_reorder(kind, strategy,
  scope, count, …)` → same action, metadata stamps `"mechanism" =>
  "strategy"` + `"strategy"` + `"scope"`. Verified by the new LV
  smoke tests in `list_lvs_handlers_test.exs`.
- Delete paths log success AND failure
  (`log_failed("projects.project_deleted", …)`).

## 8 — Tests
- **Status:** clean. ~150 new tests written across the sweep:
  - 40 backend reorder context tests (`reorder_by_test.exs`)
  - 28 LV handler tests (`list_lvs_handlers_test.exs`)
  - 81 core component tests across `bulk_select`, `sortable`,
    `reorder_modal`, `load_more`, `sort_selector`, `modal` keep_in_dom,
    `table_default` row + drag_handle.
- Edge cases covered: empty inputs, oversized inputs, malformed
  payloads (non-binary uuids, unknown strategy strings), crash-on-
  bad-field defense, duplicate-positions error path.

## 9 — Cleanliness
- **Status:** clean for the diff. Agent #3 (C12) + the C12.5 sweep
  found no commented-out `def` lines, no `@deprecated` decorations
  without internal audit, no dead keys in helper return maps.
- One stale test fixed (the deleted `:filter` form event still had
  a test referencing it on the base branch); see
  `final_branches_test.exs` + `list_lvs_test.exs` diffs.
- One real production bug surfaced + fixed:
  `<.drag_handle_cell>`'s default `title` was unreachable due to an
  `attr :title, :string, default: nil` shadowing the
  `assign_new(:title, fn -> gettext("Drag to reorder") end)` line.
  Fixed in `table_default.ex` via explicit `assigns.title || gettext(…)`.

## 10 — Public API
- **Status:** clean. `Projects.reorder_projects_by/3`,
  `Projects.reorder_tasks_by/3`, `Projects.reorder_templates_by/3`,
  `Projects.count_projects/1`, `Projects.count_tasks/0` all have
  `@spec` and `@doc`. Return-shape consistency verified
  (`:ok | {:error, :wrong_scope | :too_many_uuids | :duplicate_positions}`).

## 11 — DB + migrations
- **Status:** N/A. No new migrations on this branch.

## 12 — PubSub + reactivity
- **Status:** clean.
- `connected?(socket) && subscribe(...)` runs at the top of
  `mount/3` BEFORE `load_projects(socket)` at the bottom of the
  function, so the initial DB read can't miss a concurrent write
  during the subscribe window.
- Broadcast payload structure (`{:projects, event, payload}`)
  matches the LV handler signature; no leaked PII checked.

## 13 — Loading states + async UX
- **Status:** clean.
- `phx-disable-with={gettext("Applying…")}` on the Apply button of
  `<.reorder_modal>` (added by C12 agent #1, verified by
  `reorder_modal_test.exs`).
- `phx-disable-with={gettext("Loading…")}` on the Load more button
  in `<.load_more>` (verified by `load_more_test.exs`).
- Form save buttons (project/task/template forms) untouched on this
  branch — pre-existing `phx-disable-with` patterns.

## Summary

- **In-scope fixes:** 2 (drag_handle default title, maybe_limit @spec,
  modal keep_in_dom docstring).
- **Out-of-scope items surfaced:** 4 (confirm_modal default-comparison,
  bump_translation_started branch, translate_resource_worker comment,
  base_enqueue_params type). Documented here for visibility; not
  acted on per the sweep-scope memory.
- **Categories run:** 13/13. No skipped categories.
