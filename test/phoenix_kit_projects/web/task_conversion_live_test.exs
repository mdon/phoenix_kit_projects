defmodule PhoenixKitProjects.Web.TaskConversionLiveTest do
  @moduledoc """
  Item 9 on the project page: ⋮ "Make it a sub-project" / "Make it a
  task", one confirm naming what moves, the history line, and the
  permission (editing tasks and adding sub-projects).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Authz, Members, Outline, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, Dependency, Project}
  alias PhoenixKitProjects.Test.Repo

  import Ecto.Query

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "convert-#{System.unique_integer([:positive])}@example.com",
        "password" => "ConvertPass123!"
      })

    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)

    {:ok,
     conn: put_test_scope(conn, fake_scope(user_uuid: user.uuid)),
     project: Projects.get_project!(project.uuid),
     user: user}
  end

  defp task!(project, title, opts \\ []) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(project.uuid, %{"title" => title, "ad_hoc" => true}, %{
        "status" => "todo"
      })

    case Keyword.get(opts, :under) do
      nil -> Projects.get_assignment(a.uuid)
      parent -> elem(Outline.move(Projects.get_assignment(a.uuid), parent.uuid, :last), 1)
    end
  end

  test "a task made a sub-project and back from ⋮, connections kept, nothing deleted", ctx do
    first = task!(ctx.project, "Measure")
    fit = task!(ctx.project, "Fit the worktop")
    cut = task!(ctx.project, "Cut", under: fit)
    {:ok, _} = Projects.add_dependency(fit.uuid, first.uuid)

    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

    html =
      view
      |> element(~s(#assignment-menu-#{fit.uuid} [phx-value-event="make_subproject"]))
      |> render_click()

    assert html =~ "Make “Fit the worktop” a sub-project?"
    assert html =~ "Its subtask becomes the sub-project&#39;s task."

    html = render_click(view, "confirm_action_ok", %{})
    assert html =~ "is a sub-project now"

    link = Projects.get_assignment(fit.uuid)
    assert %Project{} = child = Repo.get(Project, link.child_project_uuid)
    assert Projects.get_assignment(cut.uuid).project_uuid == child.uuid

    assert Repo.exists?(
             from(d in Dependency,
               where: d.assignment_uuid == ^fit.uuid and d.depends_on_uuid == ^first.uuid
             )
           )

    assert Repo.exists?(
             from(e in PhoenixKit.Activity.Entry,
               where:
                 e.action == "projects.assignment_made_subproject" and
                   e.resource_uuid == ^fit.uuid
             )
           )

    # And back.
    html =
      view
      |> element(~s([phx-value-event="make_task"][phx-value-uuid="#{fit.uuid}"]))
      |> render_click()

    assert html =~ "Make “Fit the worktop” a task?"
    html = render_click(view, "confirm_action_ok", %{})
    assert html =~ "is a task now"

    row = Projects.get_assignment(fit.uuid)
    assert is_nil(row.child_project_uuid)
    assert Projects.get_assignment(cut.uuid).parent_uuid == fit.uuid
    assert Repo.get(Project, child.uuid).archived_at
    assert Repo.exists?(from(a in Assignment, where: a.uuid == ^cut.uuid))
  end

  test "a subtask offers no sub-project", ctx do
    fit = task!(ctx.project, "Fit")
    cut = task!(ctx.project, "Cut", under: fit)
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

    assert has_element?(
             view,
             ~s(#assignment-menu-#{fit.uuid} [phx-value-event="make_subproject"])
           )

    refute has_element?(
             view,
             ~s(#assignment-menu-#{cut.uuid} [phx-value-event="make_subproject"])
           )
  end

  for {floor, what} <- [{"edit_tasks", "edit tasks"}, {"create_tasks", "add sub-projects"}] do
    test "someone who may not #{what} cannot make one, even with a forged event", ctx do
      fit = task!(ctx.project, "Fit")

      {:ok, viewer} =
        Auth.register_user(%{
          "email" => "viewer-#{System.unique_integer([:positive])}@example.com",
          "password" => "ViewerPass123!"
        })

      {:ok, _} = Members.add_member(ctx.project, viewer.uuid, role: "viewer")
      {:ok, project} = Authz.set_overrides(ctx.project, %{unquote(floor) => "managers"})

      conn =
        put_test_scope(
          build_conn(),
          fake_scope(user_uuid: viewer.uuid, permissions: ["projects"])
        )

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      render_click(view, "make_subproject", %{"uuid" => fit.uuid})
      assert is_nil(Projects.get_assignment(fit.uuid).child_project_uuid)
    end
  end
end
