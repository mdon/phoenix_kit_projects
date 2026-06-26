# PR #26 review — Timeline chart settings page + cross-session reactivity (gantt 0.4.0)

- **PR:** [#26](https://github.com/BeamLabEU/phoenix_kit_projects/pull/26) — `mdon/main` → `main`
- **Merge:** `4be0083` (parents `23bf691` … `c2bebb1`)
- **Reviewer:** Claude (Opus 4.8), post-merge
- **Verdict:** ✅ Ship-ready. No correctness bugs found; the gate is fully green. Two
  judgment-call improvements are documented below and deliberately **not** fixed
  (rationale given). The PR also closes a real latent staleness bug — see
  "Latent bug this PR fixes."

## Scope

A new **Timeline-chart settings card** on `/admin/settings/projects` (a global,
`PhoenixKit.Settings`-backed config for the Gantt's bar labels / bars / toggles /
dependency-arrow routing, with a live demo chart), plus **cross-session
reactivity** so a task reorder — and project archive / unarchive / status change —
reflects on every open Timeline chart and project page. Floor bumped
`phoenix_live_gantt ~> 0.3 → ~> 0.4` to pick up the bar-label / arrow-attachment API.

Files: `gantt_display.ex` (new), `projects.ex` (+`:assignment_reordered` broadcast),
`project_gantt_live.ex`, `project_show_live.ex`, `projects_settings_live.ex`,
`mix.exs`/`mix.lock`, and four test files.

## Verifications performed (all passed)

- **Two-lists-in-sync — `GanttDisplay` enums vs the library's accepted values.**
  Cross-checked every enum the module mints against `PhoenixLiveGantt.gantt/1`'s
  `attr … values:` in the locked `phoenix_live_gantt` 0.4.0:
  - `label_position` `~w(none inside outside fit watermark)` ↔ `[:none, :inside, :outside, :fit, :watermark]` ✓
  - `label_side` `~w(auto left right)` ↔ `[:auto, :left, :right]` ✓
  - `label_overflow` `~w(truncate clip visible)` ↔ `[:truncate, :clip, :visible]` ✓
  - `bus_attach_mode` `~w(smart type_zoned center)` ↔ `[:smart, :type_zoned, :center]` ✓
  - `row_height` choice → CSS rem string (`2/2.5/3rem`), `min_bar_px`/`tiny_bar_px`
    ints, `label_fit_ratio`/`label_watermark_opacity` floats — all match the
    library attr **types**. No drift.
- **Trigger reality-check — every newly-subscribed event has a real emitter.**
  `:assignment_reordered` (`projects.ex:2805`, added here), `:project_status_changed`
  (`:991`), `:project_archived` (`:1858`), `:project_unarchived` (`:1868`). The
  last three were already broadcast pre-PR; the gantt (and `:archived`/`:unarchived`
  for the show page) simply weren't subscribed — this PR closes that gap. The
  catch-all `handle_info` would have silently dropped them, so the new
  `project_gantt_live_test` correctly pins that a handled lifecycle event reloads.
- **`String.to_atom` safety.** `GanttDisplay.enum/3` only ever calls `to_atom` on a
  value already filtered to the fixed allowed list (falls back to a literal default
  otherwise), so it is bounded — no unbounded-atom risk from settings input. The
  inline comment justifying `to_atom` over `to_existing_atom` (doesn't depend on the
  gantt module being loaded) is accurate.
- **Validation / clamping.** Enums outside the allowed set, unparseable
  ratios/ints, and unknown fields all return `:ignore` (no write); ratios clamp to
  `0.0..1.0`, `min_bar_px` to `0..min_bar_max()` (8). Locked in by
  `gantt_display_test.exs`.
- **Demo data uses only valid library API** — `PhoenixLiveGantt.Task` struct fields
  (`id/title/start/end/color/progress_pct/extra`), `:ff` connector type,
  `PhoenixLiveGantt.toggle_expanded/2`, sub-project `parent_id` + `badges` in
  `:extra`. All present in 0.4.0.
- **`@gantt_display` always assigned.** `default_assigns/1` (which reads it) is
  applied in *both* `ProjectGanttLive.mount` branches (project found / not found),
  so render never hits a missing-assign `KeyError`.
- **Default-behavior change is intentional, not a regression.** The gantt now
  defaults `label_position: :fit` (lib default is `:inside`). Fit-mode labels were
  introduced earlier in this same PR (`7e58265 "Show fit-mode bar labels …"`), so
  `:fit` is the intended baseline that the settings default mirrors.

## Gate (project `mix precommit` chain) — all green

| Step | Result |
|---|---|
| `compile --force --warnings-as-errors` | ✅ clean |
| `format --check-formatted` | ✅ clean |
| `credo --strict` | ✅ 113 files, no issues |
| `dialyzer` | ✅ passed (7 ignored via `.dialyzer_ignore.exs`, 0 unnecessary) |
| `deps.unlock --check-unused` | ✅ exit 0 |
| `hex.audit` | ✅ no retired packages |
| `mix test` | ✅ 152 passed / 0 failed |

> **Test caveat (environment).** No PostgreSQL is reachable in this review env, so
> the 628 `:integration`-tagged tests — which **includes all four of this PR's new
> DB/LiveView tests** (`GanttDisplayTest`, the reorder/lifecycle broadcast tests,
> the settings-page tests) — were auto-excluded, per the repo's "mix test never
> hard-fails on a missing DB" stance. The new tests were read and are correctly
> structured (right topics, `broadcast: false` to drive `handle_info`
> deterministically, activity-log assertions); they exercise in CI.

## Latent bug this PR fixes (positive finding)

The pre-PR `reorder_assignments` LV handler relied on a comment-claimed reload
"via the `assignment_updated` PubSub fan-out triggered by the position writes" — but
`write_assignment_positions/1` does **no** broadcast (it's a two-pass `update_all`
inside a transaction). So before this PR a task reorder:

1. never refreshed the **acting** view's server-side `@assignments` (only the
   client `SortableGrid` moved the cards optimistically — server state stayed
   stale and could snap back on the next diff), and
2. never propagated to **any other** open session or Timeline chart.

This PR fixes both: the acting handler now reloads explicitly for immediate
feedback, and `reorder_assignments` fires `:assignment_reordered` so other views
reload. The acting view also self-receives that broadcast (PubSub delivers to self)
and reloads once more — **idempotent, and consistent with every other mutating
handler in this module**, which all pair an explicit `load_assignments()` with a
self-delivered content broadcast. Not a new inefficiency.

## Findings (documented, not fixed)

### IMPROVEMENT — MEDIUM: `GanttDisplay.read/0` issues ~13 uncached settings queries, in a twice-run `mount`

`read/0` calls `PhoenixKit.Settings.get_setting/2` + `get_boolean_setting/2` ~13
times, each an **uncached** DB `SELECT` (`get_setting/1` → `Queries.get_setting_by_key/1`,
no cache; the cached path is `get_setting_cached/2`). It runs in
`ProjectGanttLive.default_assigns/1` and `ProjectsSettingsLive.mount` — and `mount`
fires twice (dead HTTP + connected WS), so a Timeline page load issues ~26 scalar
settings queries on top of the chart's per-project build.

**Why not fixed:** the surgical fix is core's batch `get_settings_cached/2`, which
swaps fresh reads for cached ones — a semantic change that interacts with the
settings page's **live-demo immediate-feedback** requirement (the demo re-`read/0`s
right after each write) and would need cache-invalidation verification plus new
tests. The gantt's dominant cost is the per-project build, not these scalar reads,
and the settings page already read scalars in `mount` pre-PR. Low reward / real
risk for a release-prep pass — flagged for maintainers to batch deliberately.

### NITPICK / IMPROVEMENT — MEDIUM: an activity-log row per slider tick

`set_gantt_label` writes a `projects.gantt_display_changed` activity row on **every**
`phx-change`, including each debounced (150 ms) step of a range-slider drag
(fit-ratio / watermark-opacity / min-bar). One deliberate drag can emit several
audit rows for a single intended change.

**Why not fixed:** how to record incremental UI tuning in the audit log is a
product/audit-policy decision for the maintainers (log on settle? coalesce? drop
slider micro-steps?), and the 150 ms debounce bounds the volume. Left as-is, on
record.

## Unrelated observation

The working tree carried pre-existing `mix.lock` drift unrelated to PR #26
(`phoenix_kit` 1.7.162→1.7.166, `phoenix_kit_comments`, `phoenix_kit_entities`,
`etcher`, `swoosh`, `plug`, `igniter`). It does not affect the published package
(Hex ships `mix.exs` deps, not the lock) and all floors in `mix.exs` remain
satisfied. Not bundled into the review/release commit.
