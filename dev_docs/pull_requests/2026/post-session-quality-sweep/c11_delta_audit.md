# C11 Delta Audit — post-session quality sweep

Per the playbook: *"for **every modified production file**, write down the test that would fail if you reverted that file's changes."*

## phoenix_kit core (`modal-to-native-dialog` vs `dev`)

| File | Change | Pinning test status |
|------|--------|----------|
| `lib/modules/sitemap/locale_path.ex` | Moduledoc rule count fix (PR #554) | N/A — doc-only |
| `lib/phoenix_kit/annotations/annotation.ex` | `:creator_uuid` excluded from `@adapter_writable_fields` | **MISSING** — adapter-payload-forgery test |
| `lib/phoenix_kit_web.ex` | Import new core component modules | N/A — wiring |
| `lib/phoenix_kit_web/components/core/bulk_select.ex` | NEW: 3 components (header_cell / cell / actions_toolbar) | **MISSING** — render tests for each component |
| `lib/phoenix_kit_web/components/core/modal.ex` | New `keep_in_dom` attr + `data-show` driven open/close | **MISSING** — keep_in_dom render test; data-show flip test |
| `lib/phoenix_kit_web/components/core/pagination.ex` | NEW: `<.load_more>` component | **MISSING** — auto-hide when total=0; button hides when loaded≥total |
| `lib/phoenix_kit_web/components/core/reorder_modal.ex` | NEW: strategy radio modal | **MISSING** — strategy radios render; scope label switches; submit shape |
| `lib/phoenix_kit_web/components/core/sort_selector.ex` | Manual-mode hint removed | **MISSING** — when `manual_field=:position` + `sort_by=:position`, direction toggle hidden |
| `lib/phoenix_kit_web/components/core/sortable.ex` | NEW: 2 components | **MISSING** — sortable_tbody enabled/disabled; sortable_row data-id + class |
| `lib/phoenix_kit_web/components/core/table_default.ex` | NEW: drag_handle_cell + group class on row | **MISSING** — `<tr>` carries `group`; drag handle has opacity-0 + group-hover classes |
| `lib/phoenix_kit_web/users/auth.ex` | PR #554 — single read of `prefixless_primary?()` | Existing integration tests cover routes; the single-read invariant could regress without notice |
| `lib/phoenix_kit_web/users/*.html.heex` | Fieldset class consistency | N/A — visual-only, parent stretches |
| `priv/static/assets/phoenix_kit.js` | 3 new hooks (BulkSelectScope, PkCheckboxIndeterminate) + PkDialog rework | **MISSING** — hook-driven LV integration tests |
| `test/integration/users/auth_locale_test.exs` | PR #554 — typed setter in cleanup | Self-pinning (it IS the test) |

**phoenix_kit core gap summary**: 9 missing pinning tests for new/changed production code.

## phoenix_kit_projects (`followup-review-pr13-fixes` vs `main`)

| File | Change | Pinning test status |
|------|--------|----------|
| `lib/phoenix_kit_projects/projects.ex` | `+429` lines: reorder_*_by/3, write_permutation/2, count_projects/1, sort helpers, log_strategy_reorder/6, maybe_limit/2 | **MISSING** — extensive context test coverage gap |
| `lib/phoenix_kit_projects/web/projects_live.ex` | `+372/-…` lines: sort handlers, load_more, open/apply_reorder, captured_uuids snapshot, sanitize_uuids | **MISSING** — LV smoke tests for each handler |
| `lib/phoenix_kit_projects/web/tasks_live.ex` | `+348/-…` lines: same shape as projects_live | **MISSING** — parallel LV smoke tests |
| `lib/phoenix_kit_projects/web/templates_live.ex` | sortable_table → table_default migration | **MISSING** — render test on template list |
| `lib/phoenix_kit_projects/web/{project,task,template}_form_live.ex` | Form behaviour deltas | **MISSING** — form save/validate tests |
| `lib/phoenix_kit_projects/translations.ex`, `ai_translate_form_helpers.ex`, `translate_resource_worker.ex`, `assignment_form_live.ex`, `components.ex` | Minor edits | Most don't need new tests; one or two might |
| `.dialyzer_ignore.exs` | New entries | N/A — tooling |
| `lib/phoenix_kit_projects/web/components/sortable_table.ex` | DELETED | N/A |

**phoenix_kit_projects gap summary**: ~5 large files with substantial new behavior, zero new tests.

## Bottom-line gap

- **phoenix_kit core**: ~9 component/hook test files missing (~30–50 tests if comprehensive)
- **phoenix_kit_projects**: 1 context test file + 2-3 LV test files, ~40–80 tests if comprehensive

Total realistic test-writing effort: **2-4 hours of focused work**, possibly more. This is the standard C10 outcome from a Phase 2 sweep.

## Highest-value tests (if scope must be cut)

1. **`projects.ex` reorder backend** — `reorder_projects_by/3` with each strategy + scope=:all and uuids list; `write_permutation/2` deadlock-safety (uuid-sort); duplicate-positions error path. Pure context tests, no LV setup. ~15-20 tests.
2. **LV apply_reorder happy path + strategy whitelist** — pin the captured_uuids → :all collapse for <2 selections, strategy validation. ~6 tests.
3. **`<.load_more>` component** — auto-hide at total=0, button at loaded≥total, push event. ~3 tests.
4. **PkDialog hook with `keep_in_dom`** — open/close via data-show flip. Requires LV integration test setup. ~3 tests.

These four cover ~80% of the regression risk for ~30 tests total — bounded scope.
