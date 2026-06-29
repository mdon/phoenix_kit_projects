# PR #27 — Overview: month calendar of running projects

**Author:** Max Don (`mdon/main`) · merged by Dmitri Don as `a239290`
**Reviewer:** Claude (Opus 4.8)
**Scope:** 9 files, +1201 / −38. New `PhoenixKitProjects.CalendarDisplay`, a List/Calendar
tab on `OverviewLive`, an overdue-animation settings card on `ProjectsSettingsLive`,
the `phoenix_live_calendar ~> 0.1` dependency, and CSS/JS source wiring.

## Summary

A high-quality, well-tested, heavily-documented PR. Every cross-cutting contract I
checked holds up; the XSS surface (raw `<style>` injection) is correctly defended;
timezone handling is consistent and unit-tested. **No bugs found** — review findings
are all minor/informational and nothing was changed in the merged code.

Validation gate (run from the repo root against installed deps):

- `mix compile --force --warnings-as-errors` — clean
- `mix format --check-formatted` — clean
- `mix credo --strict` — 0 issues (115 files)
- `mix test` (unit) — `calendar_display_test.exs` + `module_callbacks_test.exs`: **34 tests, 0 failures**
  (integration/LV tests skipped — no Postgres in this environment, per AGENTS.md stance)
- `mix dialyzer` — see release commit notes

## What I verified (and why it's correct)

- **`nav_tabs` event contract.** Core `nav_tabs` (path-less tabs) renders a
  `<button phx-click={@on_change} phx-value-tab={tab.id}>`, so clicking "Calendar"
  delivers `%{"tab" => "calendar"}` — exactly what `handle_event("switch_overview_tab",
  %{"tab" => "calendar"}, …)` matches. The list fallback clause handles `"list"`.
  No silent "tab never opens" mismatch.
- **`on_event_click` timing.** `phoenix_live_calendar` invokes the callback from its
  own `handle_event("lc_event_click", …)` (`notify_callback/3`), i.e. inside the
  parent LiveView process, so `send(self(), {:calendar_open_project, id})` reaches
  `OverviewLive`'s `handle_info` — not a render-time send loop. Mirrors the dep's own
  documented example.
- **Component/hook existence.** `nav_tabs` is imported via core `phoenix_kit_web.ex`;
  the `SyncAnimations` JS hook ships in `phoenix_live_calendar.js`; `expand_cells` /
  `fixed_weeks` / `views` / `on_event_click` / `info_label` / `<:info>` all exist on
  `CalendarComponent` 0.1.0.
- **Raw `<style>` XSS surface.** `animation_style/1` / `animation_css/1` interpolate
  only validated enums (`anim_enum` whitelist) and clamped floats (`anim_float` +
  `num/1`). Even a setting tampered outside `put_animation/2` falls back to a safe
  default on read. `Phoenix.HTML.raw/1` is safe here.
- **Timezone consistency.** One `now` (UTC, for "deadline passed?") and one local
  `today` (offset-shifted, for day placement) are computed once in `reload/1` and
  threaded through `running_tier/2`, `running_sort_key/3`, `overdue_seconds/2`,
  `days_until/3`, and `CalendarDisplay.events/6`. The local-day placement is
  unit-tested (`"places bars on the viewer-local day per the timezone offset"`).
- **Overdue-highlight date math.** Highlight `from = planned_end+1`, `to = today+1`
  (exclusive) marks exactly the overdue tail of a `[start, today+1)` bar; gated on
  `late: true` AND a planned end strictly in the past. A late-by-age project (nil
  planned_end) degrades to no highlight without crashing — by design.
- **No new N+1.** `project_tree_summary/1` was already mapped over *all* active
  projects pre-PR; the calendar reuses that same `all_summaries` list. The cards get
  the capped slice, the calendar gets the full list — no extra per-project query.
- **`reload/1` in `mount/3`.** Pre-existing, deliberate embeddable-LV exception
  (handle_params is intentionally absent so `live_render` can mount it) — documented
  in `dev_docs/embedding_audit.md`. Not introduced here.

## Findings

### IMPROVEMENT - LOW — Activity log writes per debounced slider tick
`set_calendar_anim` logs `projects.calendar_display_changed` on every `phx-change`,
including each debounced (`150ms`) range-slider step, so a single drag can emit several
entries. **Deliberately not changed:** this mirrors the existing
`toggle_gantt_flag` / `set_gantt_display` precedent (same per-change audit logging),
and the debounce already bounds the volume. Changing only the calendar side would make
the two settings cards inconsistent. Flagged for the record.

### IMPROVEMENT - LOW — Calendar work runs on every reload even when the tab is never opened
`reload/1` always computes `calendar_events` and reads the 6 overdue-animation
settings (`CalendarDisplay.read_animation/0`), and `reload/1` runs on every
`{:projects, …}` PubSub broadcast. The calendar is lazy-*rendered* (`calendar_seen?`)
but its data is eager. **Not changed:** deferring it behind `calendar_seen?` would
complicate cross-session reactivity (a broadcast while the calendar tab is open must
refresh the bars), and the cost (a handful of settings reads + a list map) matches the
dashboard's existing "recompute everything on every event" model.

### NITPICK — New activity actions not added to `AGENTS.md`
`projects.calendar_display_changed` / `projects.calendar_display_reset` aren't in the
AGENTS.md "Activity logging" action list. Pre-existing gap: the analogous
`projects.gantt_display_changed` / `_reset` aren't listed either, so the omission is
consistent with the current doc state rather than a regression.

### NITPICK — `CalendarDisplay.anim_range/1` has no catch-all clause
A public function that raises `FunctionClauseError` on an unknown field. Only ever
called internally with the four literal field names, so a fail-loud-on-programmer-error
stance is reasonable; left as-is.

## Verdict

Ship it. The merged code is correct as-is; this review accompanies the `0.16.0`
release that publishes the (previously unreleased) Overview calendar feature.
