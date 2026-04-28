defmodule PhoenixKitProjects.L10nTest do
  @moduledoc """
  Direct unit tests for the date/time formatting helpers — no DB.

  The 12 short_month branches are intentionally listed as separate
  `gettext/1` calls (see `L10n.@moduledoc`) so the string-extraction
  task can see them. Each one needs a covering test or the extractor
  silently drops a label.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.L10n

  describe "format_date/1" do
    test "returns nil for nil" do
      assert L10n.format_date(nil) == nil
    end

    test "formats a Date as `Mon DD, YYYY`" do
      assert L10n.format_date(~D[2026-04-28]) == "Apr 28, 2026"
    end

    test "formats a DateTime by reducing to its Date" do
      assert L10n.format_date(~U[2026-04-28 12:34:56Z]) == "Apr 28, 2026"
    end

    test "formats a NaiveDateTime by reducing to its Date" do
      assert L10n.format_date(~N[2026-04-28 12:34:56]) == "Apr 28, 2026"
    end
  end

  describe "format_datetime/1" do
    test "returns nil for nil" do
      assert L10n.format_datetime(nil) == nil
    end

    test "formats `Mon DD, YYYY at HH:MM`" do
      assert L10n.format_datetime(~U[2026-04-28 09:05:00Z]) == "Apr 28, 2026 at 09:05"
    end
  end

  describe "format_month_day_time/1" do
    test "returns nil for nil" do
      assert L10n.format_month_day_time(nil) == nil
    end

    test "formats `Mon DD HH:MM`" do
      assert L10n.format_month_day_time(~U[2026-12-31 23:59:00Z]) == "Dec 31 23:59"
    end
  end

  describe "format_time/1" do
    test "zero-pads single-digit hour and minute" do
      assert L10n.format_time(~U[2026-04-28 03:05:00Z]) == "03:05"
    end

    test "double-digit hour passes through" do
      assert L10n.format_time(~U[2026-04-28 23:59:00Z]) == "23:59"
    end
  end

  describe "short_month/1 — every month label" do
    test "Jan" do
      assert L10n.short_month(1) == "Jan"
    end

    test "Feb" do
      assert L10n.short_month(2) == "Feb"
    end

    test "Mar" do
      assert L10n.short_month(3) == "Mar"
    end

    test "Apr" do
      assert L10n.short_month(4) == "Apr"
    end

    test "May" do
      assert L10n.short_month(5) == "May"
    end

    test "Jun" do
      assert L10n.short_month(6) == "Jun"
    end

    test "Jul" do
      assert L10n.short_month(7) == "Jul"
    end

    test "Aug" do
      assert L10n.short_month(8) == "Aug"
    end

    test "Sep" do
      assert L10n.short_month(9) == "Sep"
    end

    test "Oct" do
      assert L10n.short_month(10) == "Oct"
    end

    test "Nov" do
      assert L10n.short_month(11) == "Nov"
    end

    test "Dec" do
      assert L10n.short_month(12) == "Dec"
    end
  end
end
