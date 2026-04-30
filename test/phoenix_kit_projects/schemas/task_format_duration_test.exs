defmodule PhoenixKitProjects.Schemas.TaskFormatDurationTest do
  @moduledoc """
  Direct unit tests for `Task.format_duration/2` — pure pattern-match
  branches per duration unit (gettext-extractable strings live as
  literals in each clause).
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Schemas.Task

  test "nil duration returns the em-dash" do
    assert Task.format_duration(nil, "hours") == "—"
  end

  test "nil unit returns the em-dash" do
    assert Task.format_duration(5, nil) == "—"
  end

  test "minutes" do
    assert Task.format_duration(15, "minutes") == "15 mins"
    assert Task.format_duration(1, "minutes") == "1 min"
  end

  test "hours" do
    assert Task.format_duration(1, "hours") == "1 hr"
    assert Task.format_duration(8, "hours") == "8 hrs"
  end

  test "days" do
    assert Task.format_duration(1, "days") == "1 d"
    assert Task.format_duration(3, "days") == "3 ds"
  end

  test "weeks" do
    assert Task.format_duration(2, "weeks") == "2 wks"
  end

  test "fortnights" do
    assert Task.format_duration(1, "fortnights") == "1 fortnight"
    assert Task.format_duration(3, "fortnights") == "3 fortnights"
  end

  test "months" do
    assert Task.format_duration(6, "months") == "6 mos"
  end

  test "years" do
    assert Task.format_duration(1, "years") == "1 yr"
    assert Task.format_duration(2, "years") == "2 yrs"
  end

  test "unknown unit falls through to raw `n unit`" do
    assert Task.format_duration(7, "decades") == "7 decades"
  end

  describe "to_hours/3 conversion table" do
    test "nil n returns 0" do
      assert Task.to_hours(nil, "hours", false) == 0
    end

    test "nil unit returns 0" do
      assert Task.to_hours(5, nil, false) == 0
    end

    test "weekdays-only conversion" do
      assert Task.to_hours(1, "days", false) == 8
      assert Task.to_hours(1, "weeks", false) == 40
      assert Task.to_hours(60, "minutes", false) == 1.0
      assert Task.to_hours(1, "fortnights", false) == 80
      assert Task.to_hours(1, "months", false) == 160
      assert Task.to_hours(1, "years", false) == 1920
    end

    test "calendar conversion (counts_weekends: true)" do
      assert Task.to_hours(1, "days", true) == 24
      assert Task.to_hours(1, "weeks", true) == 168
      assert Task.to_hours(1, "fortnights", true) == 336
      assert Task.to_hours(1, "months", true) == 720
      assert Task.to_hours(1, "years", true) == 8760
    end

    test "unknown unit defaults to 1 (passthrough)" do
      assert Task.to_hours(5, "decades", false) == 5
    end
  end

  test "duration_units/0 returns the canonical list" do
    assert Task.duration_units() == ~w(minutes hours days weeks fortnights months years)
  end
end
