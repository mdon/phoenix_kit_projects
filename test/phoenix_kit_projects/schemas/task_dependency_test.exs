defmodule PhoenixKitProjects.Schemas.TaskDependencyTest do
  @moduledoc """
  Direct unit tests for `TaskDependency.changeset/2` — covers the
  self-reference rejection + the validate_required path.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Schemas.TaskDependency

  test "self-reference (task depends on itself) is rejected" do
    same = Ecto.UUID.generate()

    cs =
      TaskDependency.changeset(%TaskDependency{}, %{
        "task_uuid" => same,
        "depends_on_task_uuid" => same
      })

    refute cs.valid?

    error_message =
      cs.errors
      |> Keyword.get(:depends_on_task_uuid)
      |> elem(0)

    assert error_message =~ "cannot depend on itself"
  end

  test "different uuids pass validation" do
    cs =
      TaskDependency.changeset(%TaskDependency{}, %{
        "task_uuid" => Ecto.UUID.generate(),
        "depends_on_task_uuid" => Ecto.UUID.generate()
      })

    assert cs.valid?
  end

  test "missing both keys fails validate_required" do
    cs = TaskDependency.changeset(%TaskDependency{}, %{})
    refute cs.valid?
    assert cs.errors |> Keyword.has_key?(:task_uuid)
    assert cs.errors |> Keyword.has_key?(:depends_on_task_uuid)
  end
end
