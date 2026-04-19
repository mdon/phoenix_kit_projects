defmodule PhoenixKitProjects.Integration.DependenciesTest do
  @moduledoc """
  Integration tests for assignment-level dependency management, including
  the multi-hop cycle detector in `add_dependency/2`.
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKitProjects.Projects

  defp new_project! do
    {:ok, p} =
      Projects.create_project(%{
        "name" => "Proj #{System.unique_integer([:positive])}",
        "status" => "active",
        "start_mode" => "immediate"
      })

    p
  end

  defp new_task!(suffix \\ nil) do
    {:ok, t} =
      Projects.create_task(%{
        "title" => "Task #{suffix || System.unique_integer([:positive])}",
        "estimated_duration" => 1,
        "estimated_duration_unit" => "hours"
      })

    t
  end

  defp new_assignment!(project, task) do
    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task.uuid,
        "status" => "todo"
      })

    a
  end

  describe "add_dependency/2" do
    test "inserts the happy-path edge" do
      project = new_project!()
      a = new_assignment!(project, new_task!())
      b = new_assignment!(project, new_task!())

      assert {:ok, _dep} = Projects.add_dependency(a.uuid, b.uuid)
    end

    test "rejects an immediate self-reference" do
      project = new_project!()
      a = new_assignment!(project, new_task!())

      assert {:error, cs} = Projects.add_dependency(a.uuid, a.uuid)
      assert %{depends_on_uuid: [_ | _]} = errors_on(cs)
    end

    test "rejects a two-hop cycle (A→B, then B→A)" do
      project = new_project!()
      a = new_assignment!(project, new_task!())
      b = new_assignment!(project, new_task!())

      assert {:ok, _} = Projects.add_dependency(a.uuid, b.uuid)

      assert {:error, cs} = Projects.add_dependency(b.uuid, a.uuid)
      assert %{depends_on_uuid: [msg | _]} = errors_on(cs)
      assert msg =~ "cycle"
    end

    test "rejects a three-hop cycle (A→B, B→C, then C→A)" do
      project = new_project!()
      a = new_assignment!(project, new_task!())
      b = new_assignment!(project, new_task!())
      c = new_assignment!(project, new_task!())

      assert {:ok, _} = Projects.add_dependency(a.uuid, b.uuid)
      assert {:ok, _} = Projects.add_dependency(b.uuid, c.uuid)

      assert {:error, cs} = Projects.add_dependency(c.uuid, a.uuid)
      assert %{depends_on_uuid: [msg | _]} = errors_on(cs)
      assert msg =~ "cycle"
    end

    test "allows parallel branches that share a common ancestor (diamond, no cycle)" do
      project = new_project!()
      root = new_assignment!(project, new_task!())
      left = new_assignment!(project, new_task!())
      right = new_assignment!(project, new_task!())

      assert {:ok, _} = Projects.add_dependency(left.uuid, root.uuid)
      assert {:ok, _} = Projects.add_dependency(right.uuid, root.uuid)
    end
  end

  describe "remove_dependency/2" do
    test "returns :not_found when the edge doesn't exist" do
      project = new_project!()
      a = new_assignment!(project, new_task!())
      b = new_assignment!(project, new_task!())

      assert Projects.remove_dependency(a.uuid, b.uuid) == {:error, :not_found}
    end

    test "removes an existing edge" do
      project = new_project!()
      a = new_assignment!(project, new_task!())
      b = new_assignment!(project, new_task!())

      {:ok, _} = Projects.add_dependency(a.uuid, b.uuid)
      assert {:ok, _} = Projects.remove_dependency(a.uuid, b.uuid)
    end
  end
end
