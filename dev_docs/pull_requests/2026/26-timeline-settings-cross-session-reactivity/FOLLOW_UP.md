# PR #26 follow-up — Timeline chart settings + cross-session reactivity

Triaged 2026-07-17 as part of the quality sweep. The review found no
correctness bugs; its two documented-not-fixed improvements were re-triaged
here: one is now fixed, one is an audit-policy call surfaced to Max.

## Fixed (Batch 1 — 2026-07-17)

- ~~IMPROVEMENT-MEDIUM: `GanttDisplay.read/0` issues ~13 uncached settings
  queries in a twice-run mount~~ — fixed with core's batch
  `PhoenixKit.Settings.get_settings_direct/1`: one uncached SELECT for all
  13 keys (`lib/phoenix_kit_projects/gantt_display.ex:96`). The reviewer's
  blocker was that the *cached* batch getter would break the settings demo's
  read-after-write freshness; `get_settings_direct/1` batches while staying
  uncached, so the semantics are unchanged. Bonus: the five boolean flags
  previously went through `get_boolean_setting/2` (a **cached** read) — they
  now share the same fresh batch, making the whole map read-consistent.

## Skipped (with rationale)

- NITPICK/IMPROVEMENT-MEDIUM: an activity-log row per debounced slider tick
  (`projects.gantt_display_changed` on every `phx-change`). How to record
  incremental UI tuning is an audit-policy decision (coalesce? log on
  settle?) — surfaced to Max in the 2026-07-17 sweep report; unchanged
  pending his call. The 150 ms debounce bounds the volume, and behavior is
  consistent with the calendar settings card (PR #27).

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_projects/gantt_display.ex` | `read/0` batches all 13 keys through one `get_settings_direct/1` call; parse helpers take the prefetched map |

## Verification

- `mix test test/phoenix_kit_projects/gantt_display_test.exs` — green (the
  existing read-after-put round-trip tests pin the refactor).
- `mix compile --warnings-as-errors` clean; full `mix precommit` run at the
  end of the sweep (see PR #30).

## Open

None.
