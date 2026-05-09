# AGENTS.md

Guidance for AI agents working on the `phoenix_kit_projects` plugin module.

## Project overview

A PhoenixKit plugin module for project + task management. Implements `PhoenixKit.Module` behaviour. Registers one admin tab (`Projects`) with subtabs:

- **Overview** — active projects with progress bars, my tasks, upcoming/setup/completed projects, stats
- **Tasks** — library of reusable task templates (title, description, duration, default dependencies, default assignee)
- **Projects** — list of projects (filterable by status)
- **Templates** — reusable project templates cloned into real projects

Plus hidden subtabs for project/task/template/assignment new/edit/show pages.

## Common commands

Run from `/www/app`, not from inside this plugin subdir:

```bash
mix compile
mix format
sudo supervisorctl restart elixir
```

## Dependencies

- `phoenix_kit` (path dep) — Module behaviour, Settings, RepoHelper, Activity
- `phoenix_kit_staff` — **hard dep.** Assignment/Task schemas reference `PhoenixKitStaff.Schemas.{Team, Department, Person}` for the polymorphic assignee; staff tables must exist for our migrations (V101 depends on V100). Both must be declared in the parent app's `mix.exs` *and* in `extra_applications`
- `phoenix_live_view`, `ecto_sql`

## Architecture

### Concepts

- **Task** — a reusable template (title, description, estimated duration with unit, optional default assignee, optional default dependencies on other tasks)
- **Project** — a container for assignments. Has start mode (`immediate` or `scheduled`), optional `counts_weekends` flag, `is_template` flag (templates are cloned into real projects), and completion tracking (`completed_at`)
- **Assignment** — a task instance within a project. Copies description/duration from the template at creation, but is independently editable. Optionally assigned to a Department/Team/Person.
- **Dependency** — "assignment A must finish before B" link, scoped to the same project
- **TaskDependency** — default dependency between two task templates, auto-applied when both templates are in the same project

### Schemas

- `PhoenixKitProjects.Schemas.Task` — `phoenix_kit_project_tasks`
- `PhoenixKitProjects.Schemas.Project` — `phoenix_kit_projects`
- `PhoenixKitProjects.Schemas.Assignment` — `phoenix_kit_project_assignments`
- `PhoenixKitProjects.Schemas.Dependency` — `phoenix_kit_project_dependencies`
- `PhoenixKitProjects.Schemas.TaskDependency` — `phoenix_kit_project_task_dependencies`

All UUIDv7 PKs. Duration units: `minutes`, `hours`, `days`, `weeks`, `fortnights`, `months`, `years` (all defined on `Schemas.Task`, which also hosts `to_hours/3` with `counts_weekends` awareness).

### Context

`PhoenixKitProjects.Projects` — everything. Task library CRUD, template deps, project CRUD, templates, assignment CRUD, dependency management, schedule/progress computations (`project_summaries/1` batch query to avoid N+1 per project), completion auto-detection (`recompute_project_completion/1`), and template cloning (`create_project_from_template/2` uses `Ecto.Repo.transaction` for atomic cloning).

### LiveViews

Under `PhoenixKitProjects.Web.*`:
- `OverviewLive` — dashboard
- `TasksLive`, `TaskFormLive` — task library
- `ProjectsLive`, `ProjectFormLive`, `ProjectShowLive` — projects
- `TemplatesLive`, `TemplateFormLive` — templates (reuses `ProjectShowLive` for view)
- `AssignmentFormLive` — add/edit task-in-project

`ProjectShowLive` is large (~900 lines) — handles the vertical timeline, status transitions, inline duration editing, per-task progress sliders, dependency badges, schedule/projected-end calculation. Sections are marked with `<%!-- ... --%>` HEEx comments for navigation.

### URL paths

Under `/admin/projects/*`: `tasks`, `list` (projects), `templates`, plus `.../new`, `.../:id`, `.../:id/edit`, and assignment routes like `list/:project_id/assignments/new`. Use `PhoenixKitProjects.Paths`.

## Database

Migrations live in `phoenix_kit` core as versioned `VNN`. Current migration: **V101** creates all project tables. When changing schema, add next `VNN`.

## Schedule math

- Durations normalized to hours via `Task.to_hours/3`. Weekdays-only mode uses 8h/day, 40h/week; calendar mode uses 24h/day, 168h/week
- Per-task `counts_weekends` overrides the project-level setting
- `calculate_schedule/2` in `ProjectShowLive` computes planned vs projected end dates:
  - **Planned** = `started_at + sum_of_task_hours` (fixed)
  - **Projected** = `now + remaining_hours / velocity` where velocity = done_hours / max(elapsed, 1h)
- Weekend work counts toward velocity even in weekdays-only projects (calendar_hours used when progress > plan)
- `progress_pct` on an assignment contributes proportionally to "done hours" only when `track_progress` is enabled

## Completion auto-detection

After every assignment status/progress/removal change, `Projects.recompute_project_completion/1` checks whether all assignments are `done` and sets `project.completed_at` accordingly. Reopening a task clears it. Logs `projects.project_completed` / `projects.project_reopened`.

## Activity logging

Every mutation logs via `PhoenixKitProjects.Activity`. Action strings: `projects.<resource>_<verb>`:

- `projects.project_created/updated/deleted/started/completed/reopened`
- `projects.template_created/updated/deleted`
- `projects.project_created_from_template`
- `projects.task_created/updated/deleted`
- `projects.task_dependency_added/removed`
- `projects.dependency_added/removed`
- `projects.assignment_created/started/completed/reopened/removed`
- `projects.assignment_progress_updated`
- `projects.assignment_duration_changed`
- `projects.assignment_tracking_toggled`

Guarded with `Code.ensure_loaded?/1` + rescue — logging never crashes mutations.

**Where to log:** activity logging happens at the **LiveView layer**, not inside context functions in `PhoenixKitProjects.Projects`. LiveViews have `actor_uuid` via `socket.assigns[:phoenix_kit_current_user]` and know the user's intent; contexts stay pure, returning `{:ok, record} | {:error, changeset}`. The LiveView logs on success.

**Sugar helpers don't log on their own:** `complete_assignment/2` and `reopen_assignment/1` are thin wrappers that delegate to the server-trusted `update_assignment_status/2`. They emit the same PubSub broadcast, but do **not** emit an activity log entry themselves. If a caller wants `projects.assignment_completed` or `projects.assignment_reopened` recorded, the caller must log it explicitly.

**Mass-assignment guard:** `Assignment.changeset/2` (used by `create_assignment/1` and `update_assignment_form/2`) does NOT cast `completed_by_uuid` or `completed_at` — those fields are server-owned and can only be set via `Assignment.status_changeset/2`, reached through `update_assignment_status/2`. This protects against form-based mass-assignment of completion metadata. The `_form` suffix on the public function is a deliberate smell: reaching for it from non-form code should trigger a second look.

## Permissions

`permission: "projects"` on all tabs. Mount guards; events trust the mount check.

## Settings keys

- `projects_enabled` — boolean, read by `PhoenixKitProjects.enabled?/0`, toggled via **Admin > Modules**. `enabled?` rescues all errors and returns `false` so missing settings tables don't crash module discovery.

## File layout

```
lib/phoenix_kit_projects.ex                  # Main module (PhoenixKit.Module behaviour)
lib/phoenix_kit_projects/
├── activity.ex                              # Activity logging wrapper
├── l10n.ex                                  # Date/time localization helpers
├── paths.ex                                 # Path helpers (/admin/projects/*)
├── projects.ex                              # Context: tasks, projects, assignments, deps
├── pub_sub.ex                               # Topics + broadcast helpers
├── schemas/
│   ├── assignment.ex                        # Mass-assignment guard + single-assignee check
│   ├── dependency.ex                        # Per-project "A → B" link (self-reference rejected)
│   ├── project.ex
│   ├── task.ex                              # Duration math (to_hours/3, format_duration/2)
│   └── task_dependency.ex                   # Template-level default deps
└── web/
    ├── assignment_form_live.ex
    ├── overview_live.ex
    ├── project_form_live.ex
    ├── project_show_live.ex                 # Large (~1000 lines) — timeline, schedule math
    ├── projects_live.ex
    ├── task_form_live.ex
    ├── tasks_live.ex
    ├── template_form_live.ex
    └── templates_live.ex
```

## Versioning & Releases

Versioning follows [SemVer](https://semver.org/). The version appears in two places that must stay in sync:

1. `mix.exs` — the `@version` module attribute
2. `lib/phoenix_kit_projects.ex` — `def version, do: "x.y.z"` (returned by the `PhoenixKit.Module` callback)

Release checklist:

1. Bump both versions; add a `CHANGELOG.md` entry
2. Run `mix precommit` — must exit clean
3. Commit ("Bump version to x.y.z") and push
4. Tag with the bare version: `git tag x.y.z && git push origin x.y.z`
5. Create a GitHub release via `gh release create`

## Conventions

- **Paths**: `PhoenixKitProjects.Paths.*` only
- **Activity**: via `PhoenixKitProjects.Activity` wrapper, always at the LiveView layer
- **Duration units + conversion**: centralized in `Schemas.Task`
- **Cross-module staff lookups**: direct calls to `PhoenixKitStaff.*` are fine — it's a declared hard dep. Wrap DB-backed lookups in a `rescue [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError]` that logs and returns an empty list so a staff DB outage never takes the projects UI down with it
- **Gettext**: all user-visible strings wrapped via `use Gettext, backend: PhoenixKitWeb.Gettext` then `gettext(...)` — shares the parent app's backend, no separate domain
- **LiveView layout**: `use PhoenixKitWeb, :live_view` (in `phoenix_kit_web.ex`) injects `layout: PhoenixKit.LayoutConfig.get_layout()` automatically. No need to wrap templates in `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` — that wrapper is for LiveViews served outside the admin live_session

## Pre-commit commands

Always run before git commit (mirrors the root `phoenix_kit` workflow):

```bash
# 1. Run the full pre-commit chain
mix precommit               # compile + format + credo --strict + dialyzer

# 2. Fix any problems surfaced above (warnings-as-errors in compile, format diffs, credo issues, dialyzer specs)

# 3. Review changes
git diff
git status

# 4. Commit
```

Step order matters: `compile` first (warnings-as-errors catches the loud stuff), then `format`, then `credo --strict`, then `dialyzer`. Run from `/www/app` so deps resolve against the workspace; `mix format` is the only one that works from inside the plugin subdir.

## Testing

Three levels:

- **Unit tests** in `test/phoenix_kit_projects/` — schemas,
  changesets, pure helpers (duration math, etc.), the `Errors` atom
  dispatcher. Always run.
- **Integration tests** in `test/phoenix_kit_projects/integration/`
  — hit a real PostgreSQL database via the Ecto sandbox. Use
  `PhoenixKitProjects.DataCase`.
- **LiveView smoke tests** in `test/phoenix_kit_projects/web/` —
  drive LVs via `Phoenix.LiveViewTest.live/2` against the test
  Endpoint + Router. Use `PhoenixKitProjects.LiveCase`.

Test infrastructure:

- `test/support/test_repo.ex` — `PhoenixKitProjects.Test.Repo`
- `test/support/test_endpoint.ex` — minimal `Phoenix.Endpoint` for
  LV tests; `server: false`, no port opened
- `test/support/test_router.ex` — minimal Router whose paths match
  `PhoenixKitProjects.Paths.*` (base scope `/en/admin/projects`)
- `test/support/test_layouts.ex` — root + app layouts; `app/1`
  renders flash divs (`#flash-info`, `#flash-error`,
  `#flash-warning`) so smoke tests can assert flash content via
  `render(view) =~ "Saved."` after click events
- `test/support/hooks.ex` — `:assign_scope` `on_mount` hook that
  reads `"phoenix_kit_test_scope"` from session and assigns
  `phoenix_kit_current_scope` + `phoenix_kit_current_user`
- `test/support/data_case.ex` — `PhoenixKitProjects.DataCase`, tags
  tests `:integration`, sets up the SQL Sandbox; hosts shared
  `fixture_task/1`, `fixture_project/1`, `fixture_template/1` and
  `errors_on/1`
- `test/support/live_case.ex` — `PhoenixKitProjects.LiveCase` with
  `fake_scope/1` + `put_test_scope/2` for plugging a real
  `%PhoenixKit.Users.Auth.Scope{}` into the test session; reuses
  fixtures from `DataCase`
- `test/support/activity_log_assertions.ex` —
  `assert_activity_logged/2` and `refute_activity_logged/2`
- `test/test_helper.exs` — starts `PhoenixKit.PubSub.Manager`,
  Hammer's `RateLimiter.Backend`, pins the URL prefix, starts
  `PhoenixKitProjects.Test.Endpoint`, and runs core's versioned
  migrations via `PhoenixKit.Migration.ensure_current/2` (V40
  extensions + uuid_generate_v7, V03 settings, V90 activities,
  V100 staff tables, V101 projects tables, V105 partial-index
  conversion) — no module-owned DDL anywhere
- `config/test.exs` — repo + Test.Endpoint config

Commands:

```bash
# First time only:
createdb phoenix_kit_projects_test

# All runs (unit + integration if DB is reachable):
mix test

# Unit tests only (DB not required):
mix test --exclude integration
```

The test helper runs core's versioned migrations via
`PhoenixKit.Migration.ensure_current/2` on every boot, so the schema
re-applies any newly-shipped Vxxx migrations automatically. No
`mix test.setup` step needed past the initial `createdb`.

Integration tests are auto-excluded if the DB isn't reachable. `mix
test` never hard-fails on a missing DB.

## CI expectations

GitHub Actions run on push and PRs: formatting check, `credo --strict`, `dialyzer`, compile with warnings-as-errors, and `mix test`. A failure in any of these blocks merge.

## Pull requests

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` with `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`). See the root `phoenix_kit/AGENTS.md` section on PR reviews for the authoritative directory layout.

Severity levels for review findings:

- `BUG - CRITICAL` — Will cause crashes, data loss, or security issues
- `BUG - HIGH` — Incorrect behavior that affects users
- `BUG - MEDIUM` — Edge cases, minor incorrect behavior
- `IMPROVEMENT - HIGH` — Significant code quality or performance issue
- `IMPROVEMENT - MEDIUM` — Better patterns or maintainability
- `NITPICK` — Style, naming, minor suggestions

## Commit message rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

## Soft-hide / archive

Archive is a **timestamp**, not a status enum. `projects.archived_at`
(added in core V112) follows the workspace's `trashed_at` convention
used by publishing posts and core files: null = visible, non-null =
hidden + audit-friendly "archived at."

Public API: `Projects.archive_project/1` and `Projects.unarchive_project/1`.
The dashboard buckets and `list_projects/1` filter on
`is_nil(archived_at)`. `Projects.list_projects/1` accepts `:archived`
opt — `false` (default, visible only), `true` (archived only), `:all`.

The derived state from `Project.derived_status/2` returns `:archived`
as the highest-priority bucket, so an archived project is always
labeled "archived" in the UI regardless of its other timestamps.

### Legacy `status` column — kept, unused

The pre-V112 `status` string column (`"active"` / `"archived"`) is
**still in the table** but no longer cast by the changeset, never read
by application code, and no longer surfaced in any UI. V112 backfilled
`archived_at = updated_at` for any row that was `status = 'archived'`
at migration time, so the soft-hide state survived the move.

The column is preserved deliberately so a future workflow concept that
legitimately wants a string lifecycle state (e.g. `"paused"`,
`"blocked"`, `"on_hold"`) can reuse the slot without another migration.
Anyone wiring such a feature must:

1. Re-introduce `status` to `Project.@optional` and `Project.changeset/2`.
2. Add a fresh `validate_inclusion(:status, …)` for the new vocabulary.
3. Update `Project.derived_status/2` priority order if the new state
   should outrank the existing buckets.
4. Decide whether to backfill existing `"active"`/`"archived"` rows.

If after a reasonable interval no such feature lands, drop the column
in a future Vxxx.

## What this module does NOT have

Pinning the deliberate non-features so future-me doesn't propose them as
"missing":

- **No tenant scoping on PubSub topics** — `projects:all` /
  `projects:tasks` / `projects:templates` fan out to every subscriber.
  Per-tenant scoping is a framework-wide gap (no other feature module
  partitions PubSub by tenant either); the right shape is to thread an
  org/tenant key through every topic when core grows that capability.
  Per-project topic (`projects:project:<uuid>`) is already safe — you
  need the UUID to subscribe.
- **No mount → handle_params refactor** — `mount/3` does the initial DB
  read in every LV. This means HTTP render + WebSocket connect each
  query. Reviewer flagged in PR #1 review item #1; left deferred because
  it's a per-LV behaviour change, not a quality-sweep refactor.
- **No event-debounce / minimal-delta on OverviewLive `handle_info`** —
  every `:projects, _, _` broadcast triggers a full dashboard reload
  (~10 queries). Reviewer flagged in PR #1 review item #7. Same scope
  reason as above.
- **No status-helper extraction** — `status_color/1` /
  `status_badge_class/1` / `status_label/1` are duplicated between
  `OverviewLive` and `ProjectShowLive`. Cosmetic; surfaced for a future
  extraction batch when a third call site appears.
- **No HTTP boundary** — context calls only PostgreSQL via Ecto and
  reads core's settings; no `Req.get` / `:httpc.request` / external
  service. So no SSRF guard, no `Req.Test`-via-app-config stub pattern.
- **No own migrations** — V100 (staff) and V101 (projects) live in core
  `phoenix_kit`. Schema changes go in the next core `VNN`. Test-only
  setup migration inlines V100 + V101 + V105 verbatim, idempotent so a
  future Hex release containing them is a no-op.
- **No own .po files** — gettext call sites live here, but translations
  live in core's `priv/gettext`.
- **No own Errors module for HTTP error shapes** — `Errors.message/1`
  covers `:not_found` / `:template_not_found` / `:task_not_found` plus
  a generic fallback. Add a new branch when a context fn introduces a
  new `{:error, atom}` shape.
