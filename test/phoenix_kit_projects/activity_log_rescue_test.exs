defmodule PhoenixKitProjects.ActivityLogRescueTest do
  @moduledoc """
  Pins the canonical post-Apr `Activity.log/2` rescue shape:

      rescue
        Postgrex.Error -> :ok
        DBConnection.OwnershipError -> :ok
        e -> Logger.warning(...)
      catch
        :exit, _reason -> :ok
      end

  Without `Postgrex.Error -> :ok` the activity-log call would raise the
  DB error all the way up to the LiveView event handler, crashing the
  user's interaction. Without `DBConnection.OwnershipError -> :ok`, an
  async PubSub broadcast crossing into a logging path without sandbox
  allowance would surface as a 1-in-10 test flake.

  Runs `async: false` because it DROPs `phoenix_kit_activities`
  inside the sandbox transaction — would deadlock against parallel
  tests touching the same table.
  """

  use PhoenixKitProjects.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias PhoenixKitProjects.Test.Repo, as: TestRepo

  describe "Activity.log/2 rescue widened to canonical post-Apr shape" do
    test "Postgrex.Error from missing phoenix_kit_activities is swallowed without Logger.warning" do
      # DROP inside the sandbox transaction. The sandbox rolls back at
      # test exit so the schema is restored automatically.
      SQL.query!(TestRepo, "DROP TABLE IF EXISTS phoenix_kit_activities CASCADE")

      log =
        capture_log(fn ->
          # MUST NOT raise — Postgrex.Error from the missing table must
          # be caught (either by core's own rescue or by our wrapper's).
          # The point of our wrapper rescue is that we don't ADD a
          # Logger.warning on top of an already-handled DB error. Core
          # may surface `{:error, %Postgrex.Error{}}` which is fine —
          # the contract is "never crashes the caller."
          result = PhoenixKitProjects.Activity.log("projects.test", [])

          assert match?({:error, %Postgrex.Error{}}, result) or result == :ok,
                 "expected :ok or {:error, %Postgrex.Error{}}, got #{inspect(result)}"
        end)

      refute log =~ "[Projects] Activity logging error",
             "wrapper Logger.warning fired for an expected DB-shape error: #{log}"
    end

    test "source includes the canonical rescue/catch shape" do
      source = File.read!("lib/phoenix_kit_projects/activity.ex")
      assert source =~ ~r/Postgrex\.Error\s*->\s*\n?\s*:ok/
      assert source =~ ~r/DBConnection\.OwnershipError\s*->\s*\n?\s*:ok/
      assert source =~ ~r/:exit,\s*_reason\s*->\s*:ok/
    end

    test "DBConnection.OwnershipError rescue swallows cross-process call" do
      # Spawn a bare process (not Task.async — that propagates the
      # caller chain so the spawned process inherits sandbox
      # ownership). A bare `spawn` doesn't, so the spawned process
      # can't check out a connection → `DBConnection.OwnershipError`.
      # Our wrapper rescue catches it and returns `:ok`.
      parent = self()
      ref = make_ref()

      :proc_lib.spawn(fn ->
        # No `Sandbox.allow/3`, no caller-chain inheritance — this
        # process is fully outside the sandbox.
        Process.put(:"$callers", [])

        result =
          try do
            PhoenixKitProjects.Activity.log("projects.test", [])
          rescue
            e -> {:rescued, e}
          catch
            kind, reason -> {:caught, kind, reason}
          end

        send(parent, {ref, result})
      end)

      assert_receive {^ref, result}, 5_000

      # If our rescue is in place: result is :ok (or some non-crash
      # tuple from core). If our rescue is missing: result would be
      # `{:rescued, %DBConnection.OwnershipError{}}` from the test's
      # outer try/rescue — which would fail this assertion.
      refute match?({:rescued, %DBConnection.OwnershipError{}}, result),
             "OwnershipError leaked past Activity.log/2 rescue: #{inspect(result)}"

      refute match?({:caught, :exit, _}, result),
             "exit signal leaked past Activity.log/2 catch: #{inspect(result)}"
    end
  end
end
