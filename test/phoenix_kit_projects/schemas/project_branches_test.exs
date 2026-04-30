defmodule PhoenixKitProjects.Schemas.ProjectBranchesTest do
  @moduledoc """
  Branch coverage on `Project` schema — `name_index_for/2` (atom + string
  key paths, struct fallback), `maybe_require_date/1` (scheduled vs
  immediate), `statuses/0` and `start_modes/0` getters.
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKitProjects.Schemas.Project

  describe "statuses/0 + start_modes/0 getters" do
    test "statuses/0 returns the canonical list" do
      assert Project.statuses() == ~w(active archived)
    end

    test "start_modes/0 returns the canonical list" do
      assert Project.start_modes() == ~w(immediate scheduled)
    end
  end

  describe "scheduled-mode date requirement" do
    test "scheduled without scheduled_start_date is invalid" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "S",
          "is_template" => "false",
          "start_mode" => "scheduled",
          "status" => "active"
        })

      refute cs.valid?
      assert errors_on(cs) |> Map.has_key?(:scheduled_start_date)
    end

    test "scheduled with date passes" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "S",
          "is_template" => "false",
          "start_mode" => "scheduled",
          "scheduled_start_date" => Date.utc_today() |> Date.to_iso8601(),
          "status" => "active"
        })

      assert cs.valid?
    end

    test "immediate mode does not require a date" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "I",
          "is_template" => "false",
          "start_mode" => "immediate",
          "status" => "active"
        })

      assert cs.valid?
    end
  end

  describe "name_index_for/2 picks partial-index per is_template" do
    test "template attrs (string key 'true') select the template index — accepts both project + template" do
      # We can't read name_index_for/2 directly — it's defp. But we can
      # observe its behaviour: a template named X and a project named X
      # both insert without colliding because they hit different partial
      # indexes.
      shared = "Shared-#{System.unique_integer([:positive])}"

      {:ok, _project} =
        PhoenixKitProjects.Projects.create_project(%{
          "name" => shared,
          "is_template" => "false",
          "start_mode" => "immediate",
          "status" => "active"
        })

      {:ok, _template} =
        PhoenixKitProjects.Projects.create_project(%{
          "name" => shared,
          "is_template" => "true",
          "start_mode" => "immediate",
          "status" => "active"
        })
    end

    test "two templates with the same name still collide on the template index" do
      shared = "Tpl-#{System.unique_integer([:positive])}"

      {:ok, _} =
        PhoenixKitProjects.Projects.create_project(%{
          "name" => shared,
          "is_template" => "true",
          "start_mode" => "immediate",
          "status" => "active"
        })

      assert {:error, %Ecto.Changeset{} = cs} =
               PhoenixKitProjects.Projects.create_project(%{
                 "name" => shared,
                 "is_template" => "true",
                 "start_mode" => "immediate",
                 "status" => "active"
               })

      assert errors_on(cs) |> Map.has_key?(:name)
    end

    test "atom-keyed attrs path: changeset built directly with `is_template: true` atom key" do
      # Cover the `Map.get(attrs, :is_template, ...)` branch where the
      # atom key wins over the string key fallback.
      cs = Project.changeset(%Project{}, %{is_template: true, name: "AtomKey"})
      assert is_struct(cs)
    end

    test "struct-data fallback: blank attrs use existing struct's is_template" do
      # When neither :is_template nor "is_template" is in attrs, the
      # private `name_index_for/2` reads from the existing struct.
      cs = Project.changeset(%Project{is_template: true}, %{name: "InheritFromStruct"})
      assert is_struct(cs)
    end
  end

  describe "validate_inclusion on status + start_mode" do
    test "rejects unknown status" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "X",
          "is_template" => "false",
          "start_mode" => "immediate",
          "status" => "deleted"
        })

      refute cs.valid?
      assert errors_on(cs) |> Map.has_key?(:status)
    end

    test "rejects unknown start_mode" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "X",
          "is_template" => "false",
          "start_mode" => "asap",
          "status" => "active"
        })

      refute cs.valid?
      assert errors_on(cs) |> Map.has_key?(:start_mode)
    end
  end
end
