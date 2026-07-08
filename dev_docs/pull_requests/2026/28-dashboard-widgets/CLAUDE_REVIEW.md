# PR #28 — Dashboard widgets: seven-widget provider for `phoenix_kit_dashboards`

**Author:** Max Don (`mdon/main`) · merged by Dmitri Don as `42bc030`
**Reviewer:** Claude (Opus 4.8)
**Scope:** 14 files, +1368 / −16. New `PhoenixKitProjects.DashboardWidgets` catalog +
seven `Phoenix.LiveComponent` widgets under `web/widgets/` + shared `Helpers`, the
duck-typed `phoenix_kit_widgets/0` delegate, `DerivedStatusBadge.workflow_color/1`
promoted to public, and a catalog test.

## Summary

Solid, well-structured PR. The duck-typed one-way contract, the lenient project
resolver, the security-conscious reuse of the hex-color guard, and the English-catalog
/ gettext-content split all hold up against the sources of truth. Every context
function, schema field, association, and lifecycle atom the widgets touch was
cross-checked against `Projects`, `Project`, `Assignment`, and `Statuses` — no
missing-preload or drifted-atom regressions.

**One real bug found and fixed:** the `only_mine` filter on the Deadlines widget was
applied *after* the row cap, so "Only my projects" under-reported (could render empty
while the viewer has qualifying projects). Fixed with a pure, unit-tested
`scope_and_limit/4` that filters before capping.

Validation gate (run from the repo root against installed deps):

- `mix compile --force --warnings-as-errors` — clean
- `mix format --check-formatted` — clean
- `mix credo --strict` — clean
- `mix test` (unit) — `dashboard_widgets_test.exs`: green (integration/LV tests skipped —
  no Postgres in this environment, per AGENTS.md stance)
- `mix dialyzer` — see release commit notes

## Findings

### BUG - HIGH — `only_mine` filtered after the row cap (FIXED)

`deadlines_widget.ex`. The pipeline was:

```elixir
rows =
  limit(settings)
  |> deadline_rows()                       # list_active_projects → summaries → filter → sort → Enum.take(limit)
  |> maybe_only_mine(only_mine?, viewer)   # narrow to the viewer's projects — AFTER the take
```

`deadline_rows/1` already did `Enum.take(limit)` across **all** active projects, so
`maybe_only_mine` narrowed the *already-capped* global top-N to the viewer's projects.

**Failure scenario:** `Max rows = 6`, 20 active projects with deadlines, and the six
nearest are all other people's. The viewer's own running projects (whose deadlines sit
at rank 7–10) are cut by `take(6)` *before* the mine-filter runs, so the widget renders
"No running projects with a planned end" even though the viewer has four. "Only my
projects" silently drops the viewer's real deadlines.

Introduced in commit `19f2336` ("Add the only_mine filter to the deadlines widget"):
the filter was bolted onto the output of `deadline_rows/1` without noticing the
`take/2` already inside it. Note the sibling filter (`planned_end && progress < 100`)
*is* correctly before the take — only `only_mine` was misordered.

**Fix:** split the cap out of candidate generation and filter first:

- `deadline_rows/1` → `deadline_candidates/0` (drops the `Enum.take`; keeps the
  `rescue _ -> []`).
- new pure `scope_and_limit(rows, only_mine?, mine_uuids, limit)` — `filter_mine` then
  `Enum.take`; preserves "no resolvable viewer ⇒ [] (never leak all)".
- the staff lookup (`list_assignments_for_user/1`) is now only run when `only_mine?`.

Locked in by a new unit test asserting the viewer's rank-3/4 rows survive a cap of 2
when the two nearest aren't theirs, that a nil viewer yields `[]`, and that
`only_mine? = false` is a plain cap.

### IMPROVEMENT - MEDIUM — DB-read resilience is applied unevenly (documented, not fixed)

AGENTS.md's widget conventions say "never crash the host dashboard," and a raising
LiveComponent `update/3` propagates to the host LiveView. Two widgets honor this by
rescuing their read (`DeadlinesWidget.deadline_candidates` → `[]`,
`WorkloadWidget.task_counts` → zero-map), but the other primary reads are unguarded:
`OngoingTasksWidget.list_assignments/1`, `ProjectStatus`/`ProjectScheduleWidget`'s
`project_summary/1`, and `ProjectsBoardWidget` / `WorkloadWidget`'s bare
`list_projects/0` + `statuses_for_projects/1`. So a transient DB error (or mid-migration
missing table) crashes the host from some widgets but degrades gracefully from others.

**Not fixed, deliberately:** `available?/0` already guards the common "module disabled"
case; the host's crash-isolation can't be verified from this repo (`phoenix_kit_dashboards`
is intentionally not a dependency); and the two existing rescues are themselves untested.
Sprinkling five more untested `rescue`s across multi-assign fallbacks (status/schedule
would need a *generic* empty state distinct from "no project found") is speculative
belt-and-suspenders better done as a deliberate, tested resilience pass than piecemeal
in a review. Flagging so the invariant/inconsistency is on record.

### NITPICK — Workload "detailed" omits `:setup` projects from the breakdown

`workload_widget.ex` shows Running / Overdue / Scheduled / Completed KPIs, but
`Project.derived_status/1` also returns `:setup` (immediate-start, not-yet-started —
a common state for freshly-created projects). `list_projects/0` returns those, so they
count toward "Projects · N" but appear in none of the four tiles, i.e. the tiles can
sum to less than the total. Left as-is: adding a fifth tile is a layout/min-size change
(`grid-cols-4` → `-5`) and a design decision, not a correctness fix.

## What I verified (and why it's correct)

- **Lifecycle atoms don't drift.** `Project.derived_status/1` returns
  `:archived | :template | :completed | :running | :overdue | :scheduled | :setup`.
  `list_projects/0` excludes templates, archived, and subprojects, so the board's
  `@lifecycle_rank` (which omits `:template`/`:archived`) never meets them in practice;
  `:template`/unknown fall through to the neutral `tint/dot/label` clauses anyway. No
  silently-dropped bucket.
- **Every context call matches its source.** `project_summaries/1` returns
  `%{project, total, done, in_progress, progress_pct, total_hours, planned_end,
  subproject_count}` — exactly the keys the Deadlines/Status/Schedule widgets read.
  `assignment_status_counts/0` is string-keyed (`"todo"/"in_progress"/"done"`), matching
  the Workload tiles. `list_active_projects/0` feeds `project_summaries/1` as expected.
- **Preloads cover every association dereferenced.** `list_assignments/1` preloads
  `:task`, `:child_project`, and the three assignees, so `OngoingTasksWidget`'s
  `assignee/1` + `Assignment.label/1` never hit a `NotLoaded`. `list_assignments_for_user/1`
  preloads `[:task, :project]`, matching `MyTasksWidget`'s reads (it never touches an
  assignee). Where an assoc could be `NotLoaded`, the guard clauses (`%{name: n}`,
  `%Person{}`, `%Project{}`) fail closed to `nil`, not a crash.
- **`workflow_color/1` promotion is safe.** Now a public `@doc false` def but the body
  is unchanged — the `@hex_color` regex still rejects any non-`#hex` string before it
  reaches the inline `style`. The board's `:if` guards on `workflow_color(map || %{})`
  so the `style` attribute (called without the `|| %{}`) is only evaluated when the
  status map is real. No XSS surface, no nil interpolation.
- **`filter-before-take` is correct in the other list widgets.**
  `OngoingTasksWidget` filters `status in ~w(todo in_progress)` *before* `Enum.take` ✓;
  `MyTasksWidget` takes after a context query that already scopes to the user's non-done
  assignments ✓. Deadlines was the lone exception (fixed above).
- **Catalog is DB-safe to build at import.** `project_options/0` runs `list_projects/0`
  but rescues to the blank prompt, so `DashboardWidgets.all()` (and the `async: true`
  catalog test with no sandbox checkout) never raises — the prompt tuple `{_, ""}` is
  always first, which the tests assert.
- **English catalog vs gettext content.** Catalog names/descriptions/labels are plain
  English (the dashboards contract caches them); widget-rendered strings use
  `PhoenixKitProjects.Gettext`. Matches the documented convention.
