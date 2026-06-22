# Code Review: PR #25 — Drop the Gantt dependency sort; lay out in the given order with gantt 0.3.0

**Reviewer:** Claude (Opus 4.8) — review performed with the `elixir-thinking` skill pack loaded.
**Date:** 2026-06-22
**PR:** https://github.com/BeamLabEU/phoenix_kit_projects/pull/25 (merged, `f1a2236`)
**State:** MERGED — review captured post-merge for the dev_docs trail.
**Scope:** 21 additions / 123 deletions across 4 files (`project_gantt_live.ex`, `mix.exs`, `mix.lock`, `project_gantt_live_test.exs`).

---

## Overall

A clean, well-reasoned revert. PR #24/0.13.0 had added a greedy stable topological sort
(`order_by_dependencies/2` + `emit_in_dependency_order/4`, ~70 lines) so a prerequisite was
always charted above the task depending on it — because on `phoenix_live_gantt` 0.2.x a
manual order that put a prerequisite *after* its dependent drew a tangled backward "conflict"
detour. PR #25 deletes all of that: `phoenix_live_gantt` 0.3.0 ships a connector router that
lays out *any* task order followably, so the Timeline now charts tasks in raw drag `position`
again and a violating order shows an honest backward arrow instead of being silently re-sorted.

The mechanical change is correct and the precommit gate is fully green (format,
`compile --warnings-as-errors` against gantt 0.3.0, `deps.unlock --check-unused`, `hex.audit`,
credo `--strict`, dialyzer). The diff is a tidy removal with no dead code left behind — the
only surviving reference to the removed helpers is the historical 0.13.0 CHANGELOG entry, which
is correct to leave in place.

One material release-hygiene issue (R1) had to be fixed before publishing; two LOW code/test
observations are noted but non-blocking.

---

## RELEASE — BLOCKING (fixed in this release)

### R1. The working tree reverted 0.13.0's behavior but kept `@version "0.13.0"` and the 0.13.0 CHANGELOG entry

**Files:** `mix.exs:4`, `CHANGELOG.md`

`phoenix_kit_projects` `0.13.0` is **already published on Hex** (2026-06-22) with the
dependency-ordering behavior and `phoenix_live_gantt` 0.2.0. PR #25 reverted exactly that
behavior and bumped the gantt floor to 0.3 — but left `@version` at `0.13.0` and left the
0.13.0 CHANGELOG entry ("**Timeline (Gantt) lays tasks out in dependency order.**") untouched.

So before this fix the working tree at `0.13.0` shipped behavior that contradicted *both* its
own CHANGELOG entry *and* the artifact already on Hex under the same version number. A user who
pinned `0.13.0` and a user who built from `main` would get opposite Timeline ordering.

**Fix (applied):** bump to **0.14.0** and add a CHANGELOG entry that documents the reversal
explicitly (a minor, not a patch, because it is a behavioral revert of 0.13.0's headline
feature — a patch on top of 0.13.0 would imply the dependency-ordering is still the contract).
The 0.13.0 entry is left intact: it correctly describes what 0.13.0 ships.

---

## IMPROVEMENT — LOW (applied)

### 2. The rewritten test asserted the order claim but not the connector claim

**File:** `test/phoenix_kit_projects/web/project_gantt_live_test.exs:119-141`

The old test "charts a prerequisite before its dependent…" asserted three things: row order,
bar-left ordering (`bar_left_pct/2`), and the *absence* of a conflict-connector class. The
rewrite ("keeps the user's drag order instead of reordering by dependency") kept only the row
order assertion and deleted the `bar_left_pct/2` helper. That leaves the PR's central claim —
"the gantt's connector router draws the resulting backward dependency followably" — asserted in
a *comment* but verified by *no assertion*: the test proves rows aren't reordered, but not that
the backward dependency still becomes a connector at all.

**Fix (applied):** added three assertions mirroring the already-passing "maps a dependency to a
connector path" test (#105) — `lg-connector` plus `data-from-id="#{a2.uuid}"` /
`data-to-id="#{a1.uuid}"` (a1 depends on a2, so the edge runs prerequisite→dependent). This
verifies the edge is still drawn under a backward order rather than dropped, which is the whole
justification for removing the pre-sort. Kept low-risk by reusing a proven assertion pattern.

**Not done (deliberately):** the old test's `refute … "lg-connector stroke-current text-error"`
inverse — asserting the backward order now *does* carry the conflict marker the comment promises
("flags it honestly") — was **not** re-added, because gantt 0.3.0's conflict-marker class/markup
isn't pinned here and asserting a specific dep-internal class is brittle. The connector library's
own suite owns that rendering contract. Worth revisiting if 0.3.x exposes a stable marker hook.

---

## OBSERVATION (no change needed)

### 3. `:order` source changed from a dense index to raw `position` — sound, but worth knowing

**File:** `lib/phoenix_kit_projects/web/project_gantt_live.ex:358`, `408-427`

`Layout.sequential`'s `:order` moved from `& &1.order` (a gap-free `Enum.with_index` sequence
that `collect_items` built per project) to `& &1.position` (the raw drag position). Two things
make this safe, and both were checked rather than assumed:

- **`position` is never nil:** `Assignment` defaults it to `0` (`assignment.ex:65`), and
  `create_assignment/2` auto-assigns `next_assignment_position/1` = `max(position) + 1` scoped to
  the project, so within a project positions are unique (no sort tie) — `clone_template/2` is the
  only path that supplies explicit positions, and those are unique in the source.
- **The two ordering signals agree.** Layout `:order` is now per-project `position`; the chart
  **row** order is the global flattened-tree index (`extra.order`, unchanged). They can differ in
  absolute value but agree on *relative* order within each parent group, because
  `list_assignments/1` returns rows `asc: position` — so the flattened index tracks position rank.
  Gaps in `position` (from deletions) are harmless: `:order` is a relative sort key, not an index.

No bug; documented so a future reader doesn't "fix" the apparent `order`/`position` divergence.

---

## Verification performed

- `mix precommit` — **green**: `format`, `compile --force --warnings-as-errors` (clean against
  gantt 0.3.0), `deps.unlock --check-unused`, `hex.audit` (no retired packages), credo `--strict`
  (no issues), dialyzer (passed).
- **DB-backed tests not run locally:** PostgreSQL is unavailable in this environment (non-root,
  no `sudo`), so the `:integration`-tagged LiveView tests — including the whole
  `ProjectGanttLiveTest` suite — auto-exclude here. They ran in CI on the PR. The test change in
  finding #2 reuses an assertion pattern already proven by the passing connector test, so the
  risk of adding it un-run locally is low.

---

## Did the PR description match the diff?

Yes. "Drop the dependency sort; lay out in the given order with gantt 0.3.0" is exactly the diff:
the topological helpers are gone, `:order` is back to `position`, the gantt floor is `~> 0.3`,
and the test was rewritten to assert order-preservation. The only thing the PR *didn't* do —
and should have — was the version/CHANGELOG bump (R1), handled in this 0.14.0 release.
