defmodule PhoenixKitProjects.ErrorsTest do
  @moduledoc """
  Per-atom EXACT-string assertions on `PhoenixKitProjects.Errors.message/1`.

  Per workspace AGENTS.md: a `is_binary/1`-loop test is a forbidden
  smell — every branch of `message/1` returns a binary by definition.
  Each atom needs the specific translated string pinned, so adding a
  new atom without adding the corresponding `gettext("...")` literal
  breaks here at test time, not later in production.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Errors

  describe "message/1" do
    test ":not_found" do
      assert Errors.message(:not_found) == "Record not found."
    end

    test ":template_not_found" do
      assert Errors.message(:template_not_found) ==
               "Template not found — it may have been deleted."
    end

    test ":task_not_found" do
      assert Errors.message(:task_not_found) ==
               "Task not found — it may have been deleted."
    end

    test "unknown atom falls back to the generic message" do
      assert Errors.message(:never_mapped_atom) ==
               "Something went wrong. Please try again."
    end
  end
end
