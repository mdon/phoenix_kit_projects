defmodule PhoenixKitProjects.Web.ProjectShowBossReviewTest do
  @moduledoc """
  The project page after the boss's review of 2026-10-30 (tim-dev): the
  assignee shown as the picker shows it, the header in one line, the
  status popup, the time-logging and comments switches, sub-project rows
  and the confirm dialogs.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Features, Projects}
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

  describe "no \"(optional)\" (item 17)" do
    test "the log-time and reopen dialogs carry no \"(optional)\"", %{conn: conn} do
      project = started_project()
      a = assignment!(project, %{"status" => "done"})
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      html = render_click(view, "open_log_time", %{"uuid" => a.uuid})
      assert html =~ ~s(id="work-entry-form-#{project.uuid}")
      refute html =~ "(optional)"

      render_click(view, "close_log_time", %{})
      html = render_click(view, "ask_reopen", %{"uuid" => a.uuid})
      assert html =~ ~s(id="reopen-form-#{project.uuid}")
      refute html =~ ~r/optional/i
    end
  end

  describe "confirm dialogs (item 10)" do
    test "deleting a task asks one question, names it, and says its subtasks go too",
         %{conn: conn} do
      project = started_project()
      parent = assignment!(project)
      child = assignment!(project)
      grandchild = assignment!(project)
      {:ok, _} = PhoenixKitProjects.Outline.move(child, parent.uuid, :last)
      {:ok, _} = PhoenixKitProjects.Outline.move(grandchild, child.uuid, :last)
      label = PhoenixKitProjects.Schemas.Assignment.label(Projects.get_assignment(parent.uuid))

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      html =
        view
        |> element(~s(#assignment-menu-#{parent.uuid} [phx-value-event="remove_assignment"]))
        |> render_click()

      assert html =~ "Delete task “#{label}”?"
      assert html =~ "Its 2 subtasks are deleted too."
      refute html =~ "Do you want to continue?"
      # No warning box repeating the question.
      refute html =~ "bg-warning/10"

      html = render_click(view, "confirm_action_ok", %{})
      assert html =~ "Task deleted."
      assert Projects.get_assignment(parent.uuid) == nil
    end

    test "a task with nothing under it gets no body line", %{conn: conn} do
      project = started_project()
      a = assignment!(project)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      html =
        view
        |> element(~s(#assignment-menu-#{a.uuid} [phx-value-event="remove_assignment"]))
        |> render_click()

      assert html =~ "Delete task “"
      refute html =~ "deleted too"
    end
  end

  describe "the header line (item 19)" do
    test "an embed puts the name, key, link and ⋮ on one centred line",
         %{conn: conn, actor_uuid: actor} do
      project = started_project()
      {:ok, project} = Projects.update_project(project, %{"external_url" => "/somewhere"})
      {:ok, _view, html} = embed(conn, project, actor)

      [line] =
        Regex.run(
          ~r/<div class="flex flex-wrap items-center gap-2 min-w-0">.*?<\/h1>.*?data-project-link.*?project-header-menu-/s,
          html
        )

      assert line =~ project.key
    end
  end

  describe "time logging on the project and billable time (item 20)" do
    test "both are off by default: no project Log time, no Logged bar, no billable box",
         %{conn: conn} do
      project = started_project()
      a = assignment!(project)
      fx = Features.gates(project)
      refute fx.project_time
      refute fx.billable

      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      refute html =~ "project-logged-"

      # A task's own Log time stays.
      html = render_click(view, "open_log_time", %{"uuid" => a.uuid})
      assert html =~ ~s(id="work-entry-form-#{project.uuid}")
      refute html =~ ~s(id="log-time-billable-#{project.uuid}")

      # A forged project-level log is refused, and a forged billable mark
      # is dropped.
      render_click(view, "close_log_time", %{})
      assert render_click(view, "open_log_time", %{}) =~ "turned off for this project"

      render_click(view, "open_log_time", %{"uuid" => a.uuid})

      render_submit(view, "save_work_entry", %{
        "hours" => "1",
        "minutes" => "0",
        "billable" => "true"
      })

      [entry] = PhoenixKitProjects.Ledger.list_entries(project.uuid)
      refute entry.billable
    end

    test "a project that turns them on gets both", %{conn: conn} do
      project = started_project()
      {:ok, project} = Features.set_flags(project, %{"project_time" => true, "billable" => true})

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")
      html = render_click(view, "open_log_time", %{})
      assert html =~ "On the project overall"
      assert html =~ ~s(id="log-time-billable-#{project.uuid}")
    end

    test "the site default is set on the settings page and a project inherits it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/settings/projects")

      view |> element("#site-flag-project_time") |> render_click()
      assert Features.site_default_values()["project_time"] == true

      project = started_project()
      assert Features.gates(project).project_time

      # The project's own value still wins.
      {:ok, project} = Features.set_flags(project, %{"project_time" => false})
      refute Features.gates(project).project_time
    end
  end

  describe "the header line instead of full-width bars (item 32)" do
    test "a not-started project gets a small Start in the header, no bar", %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      [crumbs] = Regex.run(~r/<div id="test-breadcrumb".*?<div id="test-flashes"/s, html)
      assert crumbs =~ ~s(phx-click="open_start_modal")
      refute html =~ "Not started — set up tasks, then start"
    end

    test "a started project says since when, quietly, in the header", %{conn: conn} do
      project = started_project()
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      [crumbs] = Regex.run(~r/<div id="test-breadcrumb".*?<div id="test-flashes"/s, html)
      assert crumbs =~ "since "
      refute crumbs =~ "open_start_modal"
      # The full "Started …" is the tooltip, not a bar's text.
      refute html =~ ~r/>\s*Started [A-Z]/
    end

    test "with time on the project on, the logged time is a header chip", %{conn: conn} do
      project = started_project()
      {:ok, project} = Features.set_flags(project, %{"project_time" => true})
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      [crumbs] = Regex.run(~r/<div id="test-breadcrumb".*?<div id="test-flashes"/s, html)
      assert crumbs =~ ~s(id="project-logged-#{project.uuid}")
      refute html =~ "Logged:"
    end
  end

  describe "Change status… (item 4)" do
    test "the ⋮ menu opens the status popup with the current status marked", %{conn: conn} do
      project = started_project()
      a = assignment!(project)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      html =
        view
        |> element(~s(#assignment-menu-#{a.uuid} [phx-click="open_status_change"]))
        |> render_click()

      assert html =~ ~s(id="status-change-choices-#{a.uuid}")

      assert html =~ ~r/phx-value-status="todo"[^>]*disabled/s or
               html =~ ~r/disabled[^>]*phx-value-status="todo"/s

      render_click(view, "set_status", %{"uuid" => a.uuid, "status" => "in_progress"})
      assert Projects.get_assignment(a.uuid).status == "in_progress"
    end

    test "Can be started from Waiting opens the release dialog, nothing written yet",
         %{conn: conn} do
      project = started_project()
      a = assignment!(project, %{"status" => "waiting"})
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      render_click(view, "open_status_change", %{"uuid" => a.uuid})
      html = render_click(view, "set_status", %{"uuid" => a.uuid, "status" => "todo"})

      assert html =~ ~s(id="next-up-form-#{project.uuid}")
      assert Projects.get_assignment(a.uuid).status == "waiting"
    end

    test "Done on a task that unlocks another asks next up first", %{conn: conn} do
      project = started_project()
      first = assignment!(project)
      second = assignment!(project, %{"status" => "waiting"})
      {:ok, _} = Projects.add_dependency(second.uuid, first.uuid)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      html = render_click(view, "set_status", %{"uuid" => first.uuid, "status" => "done"})
      assert html =~ ~s(id="next-up-form-#{project.uuid}")
      assert Projects.get_assignment(first.uuid).status == "todo"
    end

    test "a status changed meanwhile is not overwritten", %{conn: conn} do
      project = started_project()
      a = assignment!(project)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      # Written behind the page's back (no broadcast), so the page still
      # holds the old status when the pick arrives.
      a |> Ecto.Changeset.change(status: "done") |> PhoenixKitProjects.Test.Repo.update!()

      html =
        render_click(view, "set_status", %{
          "uuid" => a.uuid,
          "status" => "in_progress",
          "from" => "todo"
        })

      assert html =~ "This task changed meanwhile"
      assert Projects.get_assignment(a.uuid).status == "done"
    end

    test "a board card has the same entry", %{conn: conn} do
      project = started_project()
      a = assignment!(project)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")
      assert has_element?(view, ~s(#board-card-#{a.uuid} [phx-click="open_status_change"]))
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
