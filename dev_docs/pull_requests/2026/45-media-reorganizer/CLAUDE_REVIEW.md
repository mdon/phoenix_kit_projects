# PR #45 — Media reorganizer plan source for projects

**Reviewed:** 2026-09-16 · **Author:** timujinne · **Verdict:** merged; fixes
applied post-merge, shipped in 0.26.0.

+2528 across 14 commits (`085c31d`…`cb80f8d`, six rounds of review on the
branch), landed via merge `fb95d5e`.

## What it does

Adds `PhoenixKitProjects.MediaReorganizer`, a `plan/2` source for core's
`Storage.Reorganizer` engine, registered via `media_reorganizer/0` on the
module. It plans moving each project's legacy `project-<uuid>` folder to where
the `:attachments_parent_folder` / `:attachments_folder_name` hooks
(PR #44) say it belongs, and reports everything it will not move:
`:duplicate`, `:relocated`, `:orphan`, `:hook_error`, `:hook_nil`.

Checked against core 2.24.0's `Reorganizer.Source` moduledoc (the contract)
and `Reorganizer.Action.new!/1` (the shape validator), which the `libs` commit
(`6145aa3`) just locked in.

## Findings

### IMPROVEMENT - MEDIUM — A stray copy next to an ambiguous match went unreported

The contract says every extra live legacy-named copy gets its own
`:relocated` report. `resolve_entry/5` set `stray_legacy: []` for an ambiguous
project (live at root AND under the target), and `stray_relocated_actions/2`
was only fed `with_folder ++ without_folder`. So a third copy under an
unrelated parent was silent: the `:duplicate` report names only the tier
matches, and the copy surfaced only after the owner fixed the duplicate and
re-ran.

**Fixed:** the ambiguous clause keeps every `anywhere` folder that is not one
of its tier matches, and ambiguous entries go through
`stray_relocated_actions/2` too (the tier matches are claimed, so they are
never double-reported). Test: `legacy folder at root AND under the target,
plus a third copy elsewhere → duplicate + relocated`.

### NITPICK — Dead `"name (N)"` noop clause and a vacuous test (fixed)

`noop_move?/3` accepted a `"name (N)"` suffix variant as already in place.
Unreachable: every folder reaching it was found by an exact-name tier, and
`legacy_uuid/1` rejects `project-<uuid> (2)`, so such a folder is never a
candidate at all. The test pinning it (`folder already at right parent under
an accepted 'name (N)' suffix variant → nothing planned`) passed for that
reason, not the one it named. It also sat oddly with D3 (this source never
suffixes, because its own lookup never searches a suffixed name).

**Fixed:** the clause and `suffixed_variant?/2` are gone; the test now states
what actually happens — not a candidate, no action, no orphan, the hook never
called.

### NITPICK — Stale "core does not ship the engine" comments (fixed)

The moduledoc and the `media_reorganizer/0` comment said today's hex core
(2.23.x) lacks the engine. 2.24.0 ships it and is now locked. The reasoning
for no `@behaviour`/`@impl` still holds — the `~> 2.0` pin admits older cores,
and an undefined behaviour warns (warnings are errors) — so only the wording
changed. Consistent with catalogue, CRM, locations and manufacturing, which
make the same call. Follow-up: add `@behaviour`/`@impl` when the documented
core floor reaches 2.24.0.

### NITPICK — DataCase test outside `integration/` (fixed)

`media_reorganizer_test.exs` uses `DataCase` but sat in
`test/phoenix_kit_projects/`; moved to `integration/` per AGENTS.md (same
correction as PR #44).

### NITPICK — An uppercase legacy folder name is detected but never acted on (not fixed)

`candidate_project_uuids/0` downcases the uuid, so `project-<UPPERCASE>` makes
its project a candidate (and the hook is called), but every later lookup uses
the lowercase `Attachments.folder_name/1`, so no match, no stray, no report.
Not a false orphan (a test pins that). Left: `Attachments` itself never finds
or creates such a folder, so it can only be hand-made, and the cost is one
wasted hook call.

### NITPICK — `:hook_nil` does not name the parent (not fixed)

The contract phrases the report as "hook answered root for a folder living
under X". This source aggregates record labels without X. Naming it would
need the batched parent-name lookup `:relocated` already does; the label list
is enough to find the folder. Left as is.

## Verified independently

- **Action shape** — every emitted map carries `source`/`kind`/`label`/`op`
  with a string label (`Project.name` is required), no key outside
  `Action`'s known set (`order_index` stays on internal entries), and
  `on_conflict: :report`, so `Action.new!/1` accepts all of them.
- **Hook subject** — the parent hook gets the bare `%Project{}`, not
  `{:ensure, project}`. Correct: the contract forbids a Source creating
  folders, and the bare subject is `Attachments`' read-only lookup form.
- **PR #44's shared-folder hazard** — a candidate whose host name resolves to
  another project's already-migrated folder under the same parent is
  `:duplicate` (host match + legacy match), never a move into it.
- **Registry pickup** — `ModuleRegistry.all_media_reorganizers/0` calls
  `media_reorganizer/0` via `safe_call` by name, so it is collected without
  `@impl`.

## Gate

`mix precommit` clean; full `mix test` against a live Postgres.
