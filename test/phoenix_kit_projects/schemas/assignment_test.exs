defmodule PhoenixKitProjects.Schemas.AssignmentTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias PhoenixKitProjects.Schemas.Assignment

  @valid %{
    "project_uuid" => UUIDv7.generate(),
    "task_uuid" => UUIDv7.generate(),
    "status" => "todo"
  }

  describe "changeset/2 — form-facing (mass-assignment guard)" do
    test "silently drops completed_by_uuid from form input" do
      completed_by = UUIDv7.generate()
      params = Map.put(@valid, "completed_by_uuid", completed_by)

      cs = Assignment.changeset(%Assignment{}, params)

      assert cs.valid?
      refute Map.has_key?(cs.changes, :completed_by_uuid)
      assert Changeset.get_field(cs, :completed_by_uuid) == nil
    end

    test "silently drops completed_at from form input" do
      completed_at = DateTime.utc_now()
      params = Map.put(@valid, "completed_at", completed_at)

      cs = Assignment.changeset(%Assignment{}, params)

      assert cs.valid?
      refute Map.has_key?(cs.changes, :completed_at)
    end

    test "validates status enum" do
      cs = Assignment.changeset(%Assignment{}, Map.put(@valid, "status", "bogus"))
      refute cs.valid?
      assert {:status, {_, _}} = List.keyfind(cs.errors, :status, 0)
    end

    test "rejects progress_pct outside 0..100" do
      cs = Assignment.changeset(%Assignment{}, Map.put(@valid, "progress_pct", 150))
      refute cs.valid?
      assert {:progress_pct, {_, _}} = List.keyfind(cs.errors, :progress_pct, 0)

      cs2 = Assignment.changeset(%Assignment{}, Map.put(@valid, "progress_pct", -1))
      refute cs2.valid?
    end
  end

  describe "status_changeset/2 — server-trusted" do
    test "does apply completed_by_uuid when called from server" do
      completed_by = UUIDv7.generate()
      params = Map.put(@valid, "completed_by_uuid", completed_by)

      cs = Assignment.status_changeset(%Assignment{}, params)

      assert cs.valid?
      assert Changeset.get_field(cs, :completed_by_uuid) == completed_by
    end

    test "does apply completed_at when called from server" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      params = Map.put(@valid, "completed_at", now)

      cs = Assignment.status_changeset(%Assignment{}, params)

      assert cs.valid?
      assert Changeset.get_field(cs, :completed_at) == now
    end

    test "still enforces progress_pct bounds" do
      cs = Assignment.status_changeset(%Assignment{}, Map.put(@valid, "progress_pct", 101))
      refute cs.valid?
    end
  end

  describe "single-assignee validation" do
    test "allows zero assignees (unassigned)" do
      cs = Assignment.changeset(%Assignment{}, @valid)
      assert cs.valid?
    end

    test "allows exactly one of team / department / person" do
      for key <- ~w(assigned_team_uuid assigned_department_uuid assigned_person_uuid) do
        cs = Assignment.changeset(%Assignment{}, Map.put(@valid, key, UUIDv7.generate()))
        assert cs.valid?, "expected #{key}-only assignment to be valid"
      end
    end

    test "rejects two or more simultaneous assignees" do
      params =
        @valid
        |> Map.put("assigned_team_uuid", UUIDv7.generate())
        |> Map.put("assigned_person_uuid", UUIDv7.generate())

      cs = Assignment.changeset(%Assignment{}, params)
      refute cs.valid?
      assert {:assigned_team_uuid, {_, _}} = List.keyfind(cs.errors, :assigned_team_uuid, 0)
    end

    test "rejects all three set" do
      params =
        @valid
        |> Map.put("assigned_team_uuid", UUIDv7.generate())
        |> Map.put("assigned_department_uuid", UUIDv7.generate())
        |> Map.put("assigned_person_uuid", UUIDv7.generate())

      refute Assignment.changeset(%Assignment{}, params).valid?
    end
  end
end
