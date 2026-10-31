defmodule PhoenixKitProjects.Integration.RepeatsTest do
  @moduledoc """
  Item 34: a repeating task, once done, stays done and ONE next task is
  made for the next date (`Repeats`, chain V28).
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Outline, Projects, Repeats}
  alias PhoenixKitProjects.Schemas.Assignment

  setup do
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    %{project: project}
  end

  defp task!(project, title, assignment_attrs \\ %{}, opts \\ []) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        Map.merge(%{"status" => "todo"}, assignment_attrs)
      )

    case opts[:under] do
      nil -> Projects.get_assignment(a.uuid)
      parent -> elem(Outline.move(Projects.get_assignment(a.uuid), parent.uuid, :last), 1)
    end
  end

  defp done!(a) do
    {:ok, _} =
      Projects.update_assignment_status(Projects.get_assignment(a.uuid), %{
        status: "done",
        progress_pct: 100,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
  end

  test "the rule is read and written in one shape" do
    assert Repeats.normalize(%{"every" => "2", "unit" => "week"}) == %{
             "every" => 2,
             "unit" => "week"
           }

    assert Repeats.normalize(%{"every" => 0, "unit" => "week"}) == nil
    assert Repeats.normalize(%{"every" => 1, "unit" => "year"}) == nil

    assert Repeats.from_params(%{"repeat" => "2weeks", "x" => 1}) ==
             %{"repeat_rule" => %{"every" => 2, "unit" => "week"}, "x" => 1}

    assert Repeats.from_params(%{
             "repeat" => "custom",
             "repeat_every" => "10",
             "repeat_unit" => "day"
           })[
             "repeat_rule"
           ] == %{"every" => 10, "unit" => "day"}

    assert Repeats.from_params(%{"repeat" => "none"})["repeat_rule"] == nil
    assert Repeats.label(%{"every" => 2, "unit" => "week"}) == "Every 2 weeks"

    assert Repeats.shift(~U[2026-01-31 09:00:00Z], %{"every" => 1, "unit" => "month"}) ==
             ~U[2026-02-28 09:00:00Z]
  end

  test "done, it stays done and one next task comes for the next date", %{project: p} do
    deadline = ~U[2026-11-02 10:00:00Z]

    check =
      task!(p, "Check in with the client", %{
        "deadline" => deadline,
        "description" => "Call them",
        "estimated_duration" => 30,
        "estimated_duration_unit" => "minutes",
        "repeat_rule" => %{"every" => 1, "unit" => "week"}
      })

    sub = task!(p, "Ask about the doors", %{}, under: check)
    done!(sub)
    done!(check)

    old = Projects.get_assignment(check.uuid)
    assert old.status == "done"
    assert old.repeat_rule == nil

    [next] =
      Projects.list_assignments(p.uuid)
      |> Enum.filter(&(&1.repeat_rule != nil))

    assert next.uuid != check.uuid
    assert next.status == "todo"
    assert Assignment.label(next) == "Check in with the client"
    assert next.task_uuid != check.task_uuid
    assert next.description == "Call them"
    assert next.estimated_duration == 30
    assert next.deadline == ~U[2026-11-09 10:00:00Z]
    assert next.repeat_rule == %{"every" => 1, "unit" => "week"}

    # Its subtask again, not done.
    [again] = Enum.filter(Projects.list_assignments(p.uuid), &(&1.parent_uuid == next.uuid))
    assert Assignment.label(again) == "Ask about the doors"
    assert again.status == "todo"

    # Reopened and done again: no second next task.
    {:ok, _} =
      Projects.update_assignment_status(Projects.get_assignment(check.uuid), %{
        status: "todo",
        completed_at: nil
      })

    done!(check)
    assert Enum.count(Projects.list_assignments(p.uuid), &(&1.repeat_rule != nil)) == 1
  end

  test "a task that does not repeat makes nothing", %{project: p} do
    one = task!(p, "Once")
    done!(one)
    assert length(Projects.list_assignments(p.uuid)) == 1
  end
end
