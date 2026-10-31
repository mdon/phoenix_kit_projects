defmodule PhoenixKitProjects.Web.ConsistencyWalkthroughTest do
  @moduledoc """
  The consistency walk-through of 2026-10-31: the task popup is the
  reference, and the older pages follow it (no empty strips, the same
  header and footer, numbers and calendars in the page's language).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "walkthrough-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
    {:ok, conn: conn, actor_uuid: user.uuid}
  end

  defp assignment!(project, attrs \\ %{}) do
    {:ok, a} =
      Projects.create_assignment(
        Map.merge(
          %{
            "project_uuid" => project.uuid,
            "task_uuid" => fixture_task().uuid,
            "status" => "todo"
          },
          attrs
        )
      )

    a
  end

  describe "no empty strip under the add buttons (item 1)" do
    test "a project with nothing done and no schedule row has no lone progress strip",
         %{conn: conn} do
      project = fixture_project()
      assignment!(project)

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      assert html =~ "Add task"
      refute html =~ ~s(id="project-summary-#{project.uuid}")
    end

    test "the strip comes back once something is done", %{conn: conn} do
      project = fixture_project()
      assignment!(project)
      assignment!(project, %{"status" => "done"})

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      assert html =~ ~s(id="project-summary-#{project.uuid}")
    end
  end
end
