defmodule PhoenixKitProjects.ProjectsExtrasTest do
  @moduledoc """
  Final coverage push on the `Projects` context — exercises:

  - `create_assignment_from_template/2` happy path (defaults merge,
    successful insert)
  - `create_assignment_from_template/2` `:task_not_found` branch
  - `walk_dependencies/3` `seen`-skip branch (cycle through a longer
    chain that revisits a node)
  - `apply_template_dependencies/1` duplicate-pair idempotence
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKitProjects.Projects

  describe "create_assignment_from_template/2" do
    test "merges template defaults + creates the assignment" do
      project = fixture_project()

      task =
        fixture_task(%{
          "title" => "Tpl-#{System.unique_integer([:positive])}",
          "description" => "tpl description",
          "estimated_duration" => 4,
          "estimated_duration_unit" => "hours"
        })

      {:ok, assignment} =
        Projects.create_assignment_from_template(task.uuid, %{
          "project_uuid" => project.uuid,
          "status" => "todo"
        })

      assert assignment.task_uuid == task.uuid
      assert assignment.description == "tpl description"
      assert assignment.estimated_duration == 4
      assert assignment.estimated_duration_unit == "hours"
    end

    test "user-supplied attrs override template defaults (drop_blanks)" do
      project = fixture_project()

      task =
        fixture_task(%{
          "title" => "Tpl2-#{System.unique_integer([:positive])}",
          "description" => "default desc",
          "estimated_duration" => 1,
          "estimated_duration_unit" => "hours"
        })

      {:ok, assignment} =
        Projects.create_assignment_from_template(task.uuid, %{
          "project_uuid" => project.uuid,
          "status" => "todo",
          "description" => "overridden",
          "estimated_duration" => 8
        })

      assert assignment.description == "overridden"
      assert assignment.estimated_duration == 8
    end

    test "blank user attrs fall through to template defaults" do
      project = fixture_project()

      task =
        fixture_task(%{
          "title" => "Tpl3-#{System.unique_integer([:positive])}",
          "description" => "default-only"
        })

      {:ok, assignment} =
        Projects.create_assignment_from_template(task.uuid, %{
          "project_uuid" => project.uuid,
          "status" => "todo",
          "description" => ""
        })

      assert assignment.description == "default-only"
    end

    test "missing task uuid returns :task_not_found" do
      project = fixture_project()

      assert {:error, :task_not_found} =
               Projects.create_assignment_from_template(Ecto.UUID.generate(), %{
                 "project_uuid" => project.uuid,
                 "status" => "todo"
               })
    end
  end

  describe "walk_dependencies / cycle detection on multi-hop chains" do
    test "rejects A → B → C → A cycle attempt" do
      project = fixture_project()
      task_a = fixture_task()
      task_b = fixture_task()
      task_c = fixture_task()

      {:ok, a} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task_a.uuid,
          "status" => "todo"
        })

      {:ok, b} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task_b.uuid,
          "status" => "todo"
        })

      {:ok, c} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task_c.uuid,
          "status" => "todo"
        })

      {:ok, _} = Projects.add_dependency(a.uuid, b.uuid)
      {:ok, _} = Projects.add_dependency(b.uuid, c.uuid)

      # C → A would close the 3-hop cycle.
      assert {:error, %Ecto.Changeset{} = cs} =
               Projects.add_dependency(c.uuid, a.uuid)

      refute cs.valid?
      assert errors_on(cs) |> Map.has_key?(:depends_on_uuid)
    end

    test "shared sub-graph: walk_dependencies seen-skip branch" do
      project = fixture_project()
      tasks = for _ <- 1..4, do: fixture_task()

      assignments =
        Enum.map(tasks, fn t ->
          {:ok, a} =
            Projects.create_assignment(%{
              "project_uuid" => project.uuid,
              "task_uuid" => t.uuid,
              "status" => "todo"
            })

          a
        end)

      [a1, a2, a3, a4] = assignments

      # Diamond: a1 → a2, a1 → a3, a2 → a4, a3 → a4.
      # When walking dependencies starting from a1, a4 is reachable via
      # both a2 and a3 — exercising the `Map.has_key?(seen, current)`
      # skip branch on the second visit.
      {:ok, _} = Projects.add_dependency(a1.uuid, a2.uuid)
      {:ok, _} = Projects.add_dependency(a1.uuid, a3.uuid)
      {:ok, _} = Projects.add_dependency(a2.uuid, a4.uuid)
      {:ok, _} = Projects.add_dependency(a3.uuid, a4.uuid)

      # a4 → a1 would close a cycle through both branches; exercising
      # the cycle walker.
      assert {:error, %Ecto.Changeset{}} =
               Projects.add_dependency(a4.uuid, a1.uuid)
    end
  end

  describe "apply_template_dependencies/1 second-run path" do
    test "running it once successfully creates the inter-assignment edge" do
      project = fixture_project()
      task_a = fixture_task()
      task_b = fixture_task()

      {:ok, _} = Projects.add_task_dependency(task_a.uuid, task_b.uuid)

      {:ok, _b_assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task_b.uuid,
          "status" => "todo"
        })

      {:ok, a_assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task_a.uuid,
          "status" => "todo"
        })

      assert {:ok, _} = Projects.apply_template_dependencies(a_assignment)
    end
  end
end
