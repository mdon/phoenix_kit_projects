defmodule PhoenixKitProjects.ActivityActorUuidTest do
  @moduledoc """
  Direct unit tests for `Activity.actor_uuid/1` — pure socket-assigns
  reduction, no DB.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Activity

  test "extracts user.uuid from the assigns map" do
    socket = %{assigns: %{phoenix_kit_current_user: %{uuid: "u-1"}}}
    assert Activity.actor_uuid(socket) == "u-1"
  end

  test "returns nil when the user assign is missing" do
    assert Activity.actor_uuid(%{assigns: %{}}) == nil
  end

  test "returns nil when the user assign is nil" do
    assert Activity.actor_uuid(%{assigns: %{phoenix_kit_current_user: nil}}) == nil
  end

  test "returns nil when the user assign has no :uuid key" do
    assert Activity.actor_uuid(%{assigns: %{phoenix_kit_current_user: %{name: "X"}}}) == nil
  end
end
