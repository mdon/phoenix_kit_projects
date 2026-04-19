defmodule PhoenixKitProjects.Schemas.TaskTest do
  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Schemas.Task

  describe "format_duration/2" do
    test "nil cases return em dash" do
      assert Task.format_duration(nil, "hours") == "—"
      assert Task.format_duration(3, nil) == "—"
    end

    test "singular for 1" do
      assert Task.format_duration(1, "hours") == "1 hr"
      assert Task.format_duration(1, "days") == "1 d"
      assert Task.format_duration(1, "weeks") == "1 wk"
    end

    test "plural for other values" do
      assert Task.format_duration(3, "hours") == "3 hrs"
      assert Task.format_duration(6, "weeks") == "6 wks"
      assert Task.format_duration(12, "months") == "12 mos"
    end
  end

  describe "to_hours/3" do
    test "returns 0 for nil inputs" do
      assert Task.to_hours(nil, "hours", false) == 0
      assert Task.to_hours(3, nil, false) == 0
    end

    test "weekdays mode uses 8h/day" do
      assert Task.to_hours(1, "days", false) == 8
      assert Task.to_hours(1, "weeks", false) == 40
    end

    test "calendar mode uses 24h/day" do
      assert Task.to_hours(1, "days", true) == 24
      assert Task.to_hours(1, "weeks", true) == 168
    end

    test "minutes convert the same in both modes" do
      assert Task.to_hours(60, "minutes", true) == 1.0
      assert Task.to_hours(60, "minutes", false) == 1.0
    end
  end

  describe "duration_units/0" do
    test "returns the known unit atoms" do
      units = Task.duration_units()
      assert "hours" in units
      assert "days" in units
      assert "weeks" in units
      assert "years" in units
      refute "work_days" in units
    end
  end

  describe "single default-assignee validation" do
    @valid %{"title" => "Onboarding call", "estimated_duration_unit" => "hours"}

    test "allows zero default assignees" do
      assert Task.changeset(%Task{}, @valid).valid?
    end

    test "allows exactly one default assignee" do
      for key <-
            ~w(default_assigned_team_uuid default_assigned_department_uuid default_assigned_person_uuid) do
        cs = Task.changeset(%Task{}, Map.put(@valid, key, UUIDv7.generate()))
        assert cs.valid?, "expected #{key}-only default to be valid"
      end
    end

    test "rejects two or more default assignees" do
      params =
        @valid
        |> Map.put("default_assigned_team_uuid", UUIDv7.generate())
        |> Map.put("default_assigned_department_uuid", UUIDv7.generate())

      cs = Task.changeset(%Task{}, params)
      refute cs.valid?

      assert {:default_assigned_team_uuid, {_, _}} =
               List.keyfind(cs.errors, :default_assigned_team_uuid, 0)
    end
  end
end
