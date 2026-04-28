defmodule PhoenixKitProjects.EnabledRescueTest do
  @moduledoc """
  Pins the `PhoenixKitProjects.enabled?/0` rescue + catch branches.
  Per workspace AGENTS.md "Known flaky-test traps" — `enabled?/0`
  must `rescue _ -> false` for missing-table outages and `catch :exit, _`
  for sandbox-shutdown traps.

  Runs `async: false` because it DROPs `phoenix_kit_settings` inside
  the sandbox transaction — would deadlock parallel async tests
  reading the same table.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias PhoenixKitProjects.Test.Repo, as: TestRepo

  test "rescues a missing settings table → returns false" do
    SQL.query!(TestRepo, "DROP TABLE IF EXISTS phoenix_kit_settings CASCADE")

    # Without the table, `Settings.get_boolean_setting/2` raises
    # `Postgrex.Error` (relation does not exist). Our `rescue _ -> false`
    # in `enabled?/0` must catch it and return false.
    assert PhoenixKitProjects.enabled?() == false
  end

  test "catches :exit signals raised on a non-sandbox-allowed process" do
    # Spawn a bare process (not Task.async — that propagates the caller
    # chain). Without sandbox allowance, the underlying DB call inside
    # `Settings.get_boolean_setting/2` may surface as an `:exit` signal
    # from the pool checkout — which `catch :exit, _ -> false` handles.
    parent = self()
    ref = make_ref()

    :proc_lib.spawn(fn ->
      Process.put(:"$callers", [])

      result =
        try do
          PhoenixKitProjects.enabled?()
        rescue
          e -> {:rescued, e}
        catch
          kind, reason -> {:caught, kind, reason}
        end

      send(parent, {ref, result})
    end)

    assert_receive {^ref, result}, 5_000

    # Either result is `false` (our rescue/catch fired) or a non-DB
    # error tuple. The contract is "never raises out of enabled?/0".
    assert result == false or is_boolean(result),
           "enabled?/0 leaked an exception: #{inspect(result)}"
  end
end
