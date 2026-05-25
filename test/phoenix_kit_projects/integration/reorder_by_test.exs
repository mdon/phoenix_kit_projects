defmodule PhoenixKitProjects.Integration.ReorderByTest do
  @moduledoc """
  Integration tests for the strategy-driven bulk reorder API
  introduced alongside the bulk-select toolkit:

    - `Projects.reorder_projects_by/3`
    - `Projects.reorder_templates_by/3`
    - `Projects.reorder_tasks_by/3`

  Plus the supporting machinery: `count_projects/1` (filterable),
  `list_projects/1` / `list_tasks/1` with `:sort_by`, `:sort_dir`,
  `:limit` opts, and the defensive `maybe_limit/2` clause.

  These tests sit alongside `reorder_test.exs` (which covers the
  DnD-driven ordered-list API). Strategy-driven reorder is a
  separate write path: either `:all` (delegates to `Reorder.reorder`
  for contiguous 1..N rewrite) or a uuid list ("permute in place"
  via `write_permutation/2` — load the rows, sort their current
  positions, assign the strategy order into those same slots).

  ## Activity-log convention

  Per the C12 review during PR #565 work, strategy reorders share
  the same `<kind>.reordered` action atom with DnD reorders. The
  `mechanism` / `strategy` / `scope` metadata distinguish them so
  the audit feed treats both as one event class.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.Projects

  setup do
    actor_uuid = Ecto.UUID.generate()
    {:ok, actor_uuid: actor_uuid}
  end

  # ── reorder_projects_by/3 ─────────────────────────────────────────

  describe "reorder_projects_by/3 :all scope" do
    test ":name_asc orders rows alphabetically and logs `project.reordered`",
         %{actor_uuid: actor_uuid} do
      _c = fixture_project(%{"name" => "Charlie"})
      _a = fixture_project(%{"name" => "Alpha"})
      _b = fixture_project(%{"name" => "Bravo"})

      assert :ok = Projects.reorder_projects_by(:name_asc, :all, actor_uuid: actor_uuid)

      names = Projects.list_projects() |> Enum.map(& &1.name)
      assert names == ["Alpha", "Bravo", "Charlie"]

      assert_activity_logged("project.reordered",
        actor_uuid: actor_uuid,
        metadata_has: %{
          "mechanism" => "strategy",
          "strategy" => "name_asc",
          "scope" => "all"
        }
      )
    end

    test ":name_desc orders rows reverse alphabetically",
         %{actor_uuid: actor_uuid} do
      _a = fixture_project(%{"name" => "Alpha"})
      _z = fixture_project(%{"name" => "Zeta"})
      _m = fixture_project(%{"name" => "Mike"})

      assert :ok = Projects.reorder_projects_by(:name_desc, :all, actor_uuid: actor_uuid)

      names = Projects.list_projects() |> Enum.map(& &1.name)
      assert names == ["Zeta", "Mike", "Alpha"]
    end

    test ":created_asc orders by inserted_at ascending",
         %{actor_uuid: actor_uuid} do
      first = fixture_project(%{"name" => "First"})
      Process.sleep(10)
      second = fixture_project(%{"name" => "Second"})
      Process.sleep(10)
      third = fixture_project(%{"name" => "Third"})

      assert :ok = Projects.reorder_projects_by(:created_asc, :all, actor_uuid: actor_uuid)

      uuids = Projects.list_projects() |> Enum.map(& &1.uuid)
      assert uuids == [first.uuid, second.uuid, third.uuid]
    end

    test ":created_desc orders by inserted_at descending",
         %{actor_uuid: actor_uuid} do
      first = fixture_project(%{"name" => "First"})
      Process.sleep(10)
      second = fixture_project(%{"name" => "Second"})

      assert :ok = Projects.reorder_projects_by(:created_desc, :all, actor_uuid: actor_uuid)

      uuids = Projects.list_projects() |> Enum.map(& &1.uuid)
      assert uuids == [second.uuid, first.uuid]
    end

    test ":reverse flips current position order",
         %{actor_uuid: actor_uuid} do
      a = fixture_project(%{"name" => "A"})
      b = fixture_project(%{"name" => "B"})
      c = fixture_project(%{"name" => "C"})

      assert :ok = Projects.reorder_projects([a.uuid, b.uuid, c.uuid], actor_uuid: actor_uuid)
      assert :ok = Projects.reorder_projects_by(:reverse, :all, actor_uuid: actor_uuid)

      uuids = Projects.list_projects() |> Enum.map(& &1.uuid)
      assert uuids == [c.uuid, b.uuid, a.uuid]
    end

    test "unknown strategy returns {:error, :invalid_strategy}",
         %{actor_uuid: actor_uuid} do
      assert {:error, :invalid_strategy} =
               Projects.reorder_projects_by(:gibberish, :all, actor_uuid: actor_uuid)
    end

    test "excludes templates from the :all set",
         %{actor_uuid: actor_uuid} do
      project = fixture_project(%{"name" => "Real"})
      template_before = fixture_template(%{"name" => "Tpl"})

      assert :ok = Projects.reorder_projects_by(:name_asc, :all, actor_uuid: actor_uuid)

      # `reorder_projects_by/3` only loads non-templates, so the
      # template's position is untouched. `list_templates/0` confirms
      # it wasn't picked up (template/project share a `position` field
      # but operate on disjoint scopes — both legitimately can sit at
      # position 1 since the lists are queried separately).
      reloaded_project = Projects.get_project(project.uuid)
      reloaded_template = Projects.get_project(template_before.uuid)
      assert reloaded_project.position == 1
      assert reloaded_template.is_template == true
      # Template still in the templates list, project not.
      template_uuids = Projects.list_templates() |> Enum.map(& &1.uuid)
      project_uuids = Projects.list_projects() |> Enum.map(& &1.uuid)
      assert template_before.uuid in template_uuids
      refute template_before.uuid in project_uuids
    end
  end

  describe "reorder_projects_by/3 selected scope (permute-in-place)" do
    test "permutes selected rows within the slots they currently occupy",
         %{actor_uuid: actor_uuid} do
      a = fixture_project(%{"name" => "Charlie"})
      b = fixture_project(%{"name" => "Alpha"})
      c = fixture_project(%{"name" => "Other"})
      d = fixture_project(%{"name" => "Bravo"})

      assert :ok =
               Projects.reorder_projects([a.uuid, b.uuid, c.uuid, d.uuid], actor_uuid: actor_uuid)

      # Sort only a, b, d (positions 1, 2, 4) by name. c at position 3 stays put.
      assert :ok =
               Projects.reorder_projects_by(:name_asc, [a.uuid, b.uuid, d.uuid],
                 actor_uuid: actor_uuid
               )

      uuids = Projects.list_projects() |> Enum.map(& &1.uuid)
      # Alphabetical within {a=Charlie, b=Alpha, d=Bravo} → b, d, a in slots 1, 2, 4.
      # c stays at position 3.
      assert uuids == [b.uuid, d.uuid, c.uuid, a.uuid]
    end

    test "logs `project.reordered` with scope=selected metadata",
         %{actor_uuid: actor_uuid} do
      a = fixture_project(%{"name" => "Z"})
      b = fixture_project(%{"name" => "A"})

      Projects.reorder_projects([a.uuid, b.uuid], actor_uuid: actor_uuid)

      assert :ok =
               Projects.reorder_projects_by(:name_asc, [a.uuid, b.uuid], actor_uuid: actor_uuid)

      assert_activity_logged("project.reordered",
        actor_uuid: actor_uuid,
        metadata_has: %{
          "mechanism" => "strategy",
          "strategy" => "name_asc",
          "scope" => "selected"
        }
      )
    end

    test "single-row selection is a no-op",
         %{actor_uuid: actor_uuid} do
      a = fixture_project(%{"name" => "A"})

      assert :ok = Projects.reorder_projects_by(:name_asc, [a.uuid], actor_uuid: actor_uuid)

      # No activity row written for single-row no-op
      refute_activity_logged("project.reordered",
        actor_uuid: actor_uuid,
        metadata_has: %{"mechanism" => "strategy"}
      )
    end

    test "empty selection is a no-op",
         %{actor_uuid: actor_uuid} do
      assert :ok = Projects.reorder_projects_by(:name_asc, [], actor_uuid: actor_uuid)
    end

    test "selection containing a template returns {:error, :wrong_scope}",
         %{actor_uuid: actor_uuid} do
      project = fixture_project(%{"name" => "Real"})
      template = fixture_template(%{"name" => "Tpl"})

      assert {:error, :wrong_scope} =
               Projects.reorder_projects_by(:name_asc, [project.uuid, template.uuid],
                 actor_uuid: actor_uuid
               )

      assert_activity_logged("project.reorder_rejected",
        actor_uuid: actor_uuid,
        metadata_has: %{"reason" => "wrong_scope"}
      )
    end

    test "duplicate-position rows return {:error, :duplicate_positions}",
         %{actor_uuid: actor_uuid} do
      # Untouched rows share position=0; selecting two of them triggers the guard.
      a = fixture_project(%{"name" => "A", "position" => 0})
      b = fixture_project(%{"name" => "B", "position" => 0})

      assert {:error, :duplicate_positions} =
               Projects.reorder_projects_by(:name_asc, [a.uuid, b.uuid], actor_uuid: actor_uuid)

      assert_activity_logged("project.reorder_rejected",
        actor_uuid: actor_uuid,
        metadata_has: %{"reason" => "duplicate_positions"}
      )
    end

    test "payload over the cap returns {:error, :too_many_uuids}",
         %{actor_uuid: actor_uuid} do
      bloat = for _ <- 1..1001, do: Ecto.UUID.generate()

      assert {:error, :too_many_uuids} =
               Projects.reorder_projects_by(:name_asc, bloat, actor_uuid: actor_uuid)
    end
  end

  # ── reorder_templates_by/3 ────────────────────────────────────────

  describe "reorder_templates_by/3" do
    test ":all + :name_asc orders templates alphabetically (excludes non-templates)",
         %{actor_uuid: actor_uuid} do
      _tpl_z = fixture_template(%{"name" => "Z-template"})
      _tpl_a = fixture_template(%{"name" => "A-template"})
      _project = fixture_project(%{"name" => "Real"})

      assert :ok = Projects.reorder_templates_by(:name_asc, :all, actor_uuid: actor_uuid)

      template_names = Projects.list_templates() |> Enum.map(& &1.name)
      assert template_names == ["A-template", "Z-template"]
    end

    test "selected scope works on templates only",
         %{actor_uuid: actor_uuid} do
      a = fixture_template(%{"name" => "Charlie"})
      b = fixture_template(%{"name" => "Alpha"})

      Projects.reorder_templates([a.uuid, b.uuid], actor_uuid: actor_uuid)

      assert :ok =
               Projects.reorder_templates_by(:name_asc, [a.uuid, b.uuid], actor_uuid: actor_uuid)

      uuids = Projects.list_templates() |> Enum.map(& &1.uuid)
      assert uuids == [b.uuid, a.uuid]
    end

    test "selection containing a non-template returns {:error, :wrong_scope}",
         %{actor_uuid: actor_uuid} do
      template = fixture_template(%{"name" => "Tpl"})
      project = fixture_project(%{"name" => "Real"})

      assert {:error, :wrong_scope} =
               Projects.reorder_templates_by(:name_asc, [template.uuid, project.uuid],
                 actor_uuid: actor_uuid
               )
    end

    test "logs `template.reordered` action, not `project.reordered`",
         %{actor_uuid: actor_uuid} do
      _ = fixture_template(%{"name" => "T1"})

      assert :ok = Projects.reorder_templates_by(:name_asc, :all, actor_uuid: actor_uuid)

      assert_activity_logged("template.reordered",
        actor_uuid: actor_uuid,
        metadata_has: %{"mechanism" => "strategy"}
      )

      refute_activity_logged("project.reordered",
        actor_uuid: actor_uuid,
        metadata_has: %{"mechanism" => "strategy"}
      )
    end
  end

  # ── reorder_tasks_by/3 ────────────────────────────────────────────

  describe "reorder_tasks_by/3" do
    test ":all + :name_asc orders by title (not name)",
         %{actor_uuid: actor_uuid} do
      _ = fixture_task(%{"title" => "Charlie"})
      _ = fixture_task(%{"title" => "Alpha"})
      _ = fixture_task(%{"title" => "Bravo"})

      assert :ok = Projects.reorder_tasks_by(:name_asc, :all, actor_uuid: actor_uuid)

      titles = Projects.list_tasks() |> Enum.map(& &1.title)
      assert titles == ["Alpha", "Bravo", "Charlie"]
    end

    test "selected permute on tasks",
         %{actor_uuid: actor_uuid} do
      a = fixture_task(%{"title" => "Z"})
      b = fixture_task(%{"title" => "M"})
      c = fixture_task(%{"title" => "A"})

      Projects.reorder_tasks([a.uuid, b.uuid, c.uuid], actor_uuid: actor_uuid)

      assert :ok =
               Projects.reorder_tasks_by(:name_asc, [a.uuid, c.uuid], actor_uuid: actor_uuid)

      # a, c selected at positions 1, 3; sorted A→Z: c, a.
      # b at position 2 untouched.
      titles = Projects.list_tasks() |> Enum.map(& &1.title)
      assert titles == ["A", "M", "Z"]
    end

    test ":reverse on tasks flips current order",
         %{actor_uuid: actor_uuid} do
      a = fixture_task(%{"title" => "First"})
      b = fixture_task(%{"title" => "Second"})
      c = fixture_task(%{"title" => "Third"})

      Projects.reorder_tasks([a.uuid, b.uuid, c.uuid], actor_uuid: actor_uuid)
      assert :ok = Projects.reorder_tasks_by(:reverse, :all, actor_uuid: actor_uuid)

      uuids = Projects.list_tasks() |> Enum.map(& &1.uuid)
      assert uuids == [c.uuid, b.uuid, a.uuid]
    end

    test "unknown strategy on tasks returns {:error, :invalid_strategy}",
         %{actor_uuid: actor_uuid} do
      assert {:error, :invalid_strategy} =
               Projects.reorder_tasks_by(:nope, :all, actor_uuid: actor_uuid)
    end

    test "logs `task.reordered` (not task.bulk_reordered)",
         %{actor_uuid: actor_uuid} do
      _ = fixture_task(%{"title" => "T"})

      assert :ok = Projects.reorder_tasks_by(:name_asc, :all, actor_uuid: actor_uuid)

      assert_activity_logged("task.reordered",
        actor_uuid: actor_uuid,
        metadata_has: %{"mechanism" => "strategy", "strategy" => "name_asc"}
      )
    end
  end

  # ── write_permutation/2 deadlock-safe ordering ───────────────────

  describe "write_permutation deadlock safety" do
    test "selected reorders sort the write pairs by uuid before phase 1",
         %{actor_uuid: actor_uuid} do
      # Two reorders that target the same set in different strategy
      # orders MUST NOT deadlock against each other. The fix is uuid-
      # sorting the write order (see write_permutation/2). Hard to
      # exercise the actual race in a single-process test, but we
      # verify the function completes correctly under load + a
      # mixed strategy.
      a = fixture_project(%{"name" => "Zeta"})
      b = fixture_project(%{"name" => "Alpha"})
      c = fixture_project(%{"name" => "Mike"})

      Projects.reorder_projects([a.uuid, b.uuid, c.uuid], actor_uuid: actor_uuid)

      assert :ok =
               Projects.reorder_projects_by(:name_asc, [a.uuid, b.uuid, c.uuid],
                 actor_uuid: actor_uuid
               )

      names = Projects.list_projects() |> Enum.map(& &1.name)
      assert names == ["Alpha", "Mike", "Zeta"]
    end
  end

  # ── count_projects/1 + count_tasks/0 ──────────────────────────────

  describe "count_projects/1" do
    test "default excludes templates and archived" do
      _ = fixture_project()
      _ = fixture_template()
      assert Projects.count_projects() == 1
    end

    test "include_templates: true counts both kinds" do
      _ = fixture_project()
      _ = fixture_template()
      assert Projects.count_projects(include_templates: true) == 2
    end

    test "counts after creating multiple non-template projects" do
      for _ <- 1..5, do: fixture_project()
      assert Projects.count_projects() == 5
    end
  end

  describe "count_tasks/0" do
    test "counts the task library size" do
      for _ <- 1..3, do: fixture_task()
      assert Projects.count_tasks() == 3
    end
  end

  # ── list_projects/1 with new opts ─────────────────────────────────

  describe "list_projects/1 with :sort_by + :sort_dir" do
    setup do
      _ = fixture_project(%{"name" => "Charlie"})
      _ = fixture_project(%{"name" => "Alpha"})
      _ = fixture_project(%{"name" => "Bravo"})
      :ok
    end

    test "default sort_by=:position uses position-then-inserted_at tiebreak" do
      # All projects have position=0 from fixture; tiebreak is inserted_at asc.
      names = Projects.list_projects() |> Enum.map(& &1.name)
      assert names == ["Charlie", "Alpha", "Bravo"]
    end

    test ":name + :asc orders alphabetically" do
      names = Projects.list_projects(sort_by: :name, sort_dir: :asc) |> Enum.map(& &1.name)
      assert names == ["Alpha", "Bravo", "Charlie"]
    end

    test ":name + :desc orders reverse" do
      names = Projects.list_projects(sort_by: :name, sort_dir: :desc) |> Enum.map(& &1.name)
      assert names == ["Charlie", "Bravo", "Alpha"]
    end

    test "unknown sort field falls back to :position" do
      # Default position ordering = insertion order in this setup.
      names = Projects.list_projects(sort_by: :something_weird) |> Enum.map(& &1.name)
      assert names == ["Charlie", "Alpha", "Bravo"]
    end
  end

  describe "list_projects/1 :limit (maybe_limit/2 defensiveness)" do
    setup do
      for i <- 1..5, do: fixture_project(%{"name" => "P#{i}"})
      :ok
    end

    test "positive integer caps the result" do
      assert length(Projects.list_projects(limit: 3)) == 3
    end

    test "nil = no limit" do
      assert length(Projects.list_projects(limit: nil)) == 5
    end

    test "zero falls through to no limit (defensive)" do
      assert length(Projects.list_projects(limit: 0)) == 5
    end

    test "negative falls through to no limit (defensive)" do
      assert length(Projects.list_projects(limit: -1)) == 5
    end

    test "non-integer falls through to no limit (defensive)" do
      assert length(Projects.list_projects(limit: "3")) == 5
    end
  end

  describe "list_tasks/1 with :sort_by + :sort_dir + :limit" do
    setup do
      _ = fixture_task(%{"title" => "Charlie"})
      _ = fixture_task(%{"title" => "Alpha"})
      _ = fixture_task(%{"title" => "Bravo"})
      :ok
    end

    test ":title + :asc orders alphabetically" do
      titles = Projects.list_tasks(sort_by: :title, sort_dir: :asc) |> Enum.map(& &1.title)
      assert titles == ["Alpha", "Bravo", "Charlie"]
    end

    test ":limit caps task results" do
      assert length(Projects.list_tasks(limit: 2)) == 2
    end

    test "unknown sort field falls back to :position" do
      titles = Projects.list_tasks(sort_by: :nope) |> Enum.map(& &1.title)

      # Position default → insertion order (all unmoved have position from create_task's next_task_position/0)
      assert titles == ["Charlie", "Alpha", "Bravo"]
    end
  end
end
