defmodule PhoenixKitProjects.Web.ProjectShowBossReviewTest do
  @moduledoc """
  The project page after the boss's review of 2026-10-30 (tim-dev): the
  assignee shown as the picker shows it, the header in one line, the
  status popup, the time-logging and comments switches, sub-project rows
  and the confirm dialogs.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects
  alias PhoenixKitStaff.{Departments, Teams}

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "boss-review-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
    {:ok, conn: conn, actor_uuid: user.uuid}
  end

  defp started_project(attrs \\ %{}) do
    project = fixture_project(Map.merge(%{"start_mode" => "immediate"}, attrs))
    {:ok, _} = Projects.start_project(project)
    Projects.get_project!(project.uuid)
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

  defp embed(conn, project, actor_uuid, extra \\ %{}) do
    {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor_uuid, role: "member")

    live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
      session: Map.merge(%{"id" => project.uuid, "current_user_uuid" => actor_uuid}, extra)
    )
  end

  describe "no lone words on a row (item 8)" do
    test "an embed has no \"Projects\" link above its title", %{conn: conn, actor_uuid: actor} do
      project = started_project()
      {:ok, _view, html} = embed(conn, project, actor)

      refute html =~ "hero-arrow-left"
      assert html =~ project.name
    end
  end

  describe "the assignee (item 5)" do
    test "a row names its team with no \"Team:\" before it", %{conn: conn} do
      n = System.unique_integer([:positive])
      {:ok, dept} = Departments.create(%{"name" => "Dept-#{n}"})
      {:ok, team} = Teams.create(%{"name" => "Fitters-#{n}", "department_uuid" => dept.uuid})
      project = started_project()
      assignment!(project, %{"assigned_team_uuid" => team.uuid})

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      assert html =~ "Fitters-#{n}"
      refute html =~ "Team: Fitters-#{n}"
      refute html =~ ~r/Team:\s*<\/span>|Team:\s+Fitters/
      assert html =~ "hero-users"
    end
  end
end
