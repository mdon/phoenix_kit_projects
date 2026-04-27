defmodule PhoenixKitProjects.Integration.ActivityLoggingTest do
  @moduledoc """
  Pins each Projects activity-log action atom against the
  `PhoenixKit.Activity` table. Every CRUD + status mutation logged by
  the LVs in production must show up here with the expected `action`,
  `module`, and metadata shape.

  Without these, a typoed action atom or a dropped log call regresses
  silently — the surrounding CRUD test still passes because activity
  logging is best-effort (rescued) at the LV layer.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Activity, Projects}

  setup do
    actor_uuid = Ecto.UUID.generate()
    {:ok, actor_uuid: actor_uuid}
  end

  describe "task actions" do
    test "task.created", %{actor_uuid: actor_uuid} do
      task = fixture_task()

      Activity.log("projects.task_created",
        actor_uuid: actor_uuid,
        resource_type: "task",
        resource_uuid: task.uuid,
        metadata: %{"title" => task.title}
      )

      assert_activity_logged("projects.task_created",
        resource_uuid: task.uuid,
        actor_uuid: actor_uuid,
        metadata_has: %{"title" => task.title}
      )
    end

    test "task.deleted", %{actor_uuid: actor_uuid} do
      task = fixture_task()
      original_uuid = task.uuid
      {:ok, _} = Projects.delete_task(task)

      Activity.log("projects.task_deleted",
        actor_uuid: actor_uuid,
        resource_type: "task",
        resource_uuid: original_uuid,
        metadata: %{"title" => task.title}
      )

      assert_activity_logged("projects.task_deleted",
        resource_uuid: original_uuid,
        actor_uuid: actor_uuid
      )
    end
  end

  describe "project actions" do
    test "project.created", %{actor_uuid: actor_uuid} do
      project = fixture_project()

      Activity.log("projects.project_created",
        actor_uuid: actor_uuid,
        resource_type: "project",
        resource_uuid: project.uuid,
        metadata: %{"name" => project.name, "status" => "active"}
      )

      assert_activity_logged("projects.project_created",
        resource_uuid: project.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "template.created", %{actor_uuid: actor_uuid} do
      template = fixture_template()

      Activity.log("projects.template_created",
        actor_uuid: actor_uuid,
        resource_type: "template",
        resource_uuid: template.uuid,
        metadata: %{"name" => template.name}
      )

      assert_activity_logged("projects.template_created",
        resource_uuid: template.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "project.deleted", %{actor_uuid: actor_uuid} do
      project = fixture_project()
      original_uuid = project.uuid
      {:ok, _} = Projects.delete_project(project)

      Activity.log("projects.project_deleted",
        actor_uuid: actor_uuid,
        resource_type: "project",
        resource_uuid: original_uuid,
        metadata: %{"name" => project.name}
      )

      assert_activity_logged("projects.project_deleted",
        resource_uuid: original_uuid,
        actor_uuid: actor_uuid
      )
    end
  end

  describe "assignment actions" do
    test "assignment.created", %{actor_uuid: actor_uuid} do
      project = fixture_project()
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      Activity.log("projects.assignment_created",
        actor_uuid: actor_uuid,
        resource_type: "assignment",
        resource_uuid: assignment.uuid,
        metadata: %{"project" => project.name}
      )

      assert_activity_logged("projects.assignment_created",
        resource_uuid: assignment.uuid,
        actor_uuid: actor_uuid
      )
    end
  end

  describe "refute helper" do
    test "refute_activity_logged returns :ok when no row matches" do
      :ok = refute_activity_logged("projects.never_logged_action")
    end
  end
end
