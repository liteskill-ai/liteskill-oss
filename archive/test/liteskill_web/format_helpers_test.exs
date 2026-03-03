defmodule LiteskillWeb.FormatHelpersTest do
  use ExUnit.Case, async: true

  import LiteskillWeb.FormatHelpers

  describe "format_cost/1" do
    test "formats Decimal as dollar string with 4 decimals" do
      assert format_cost(Decimal.new("1.2345")) == "$1.2345"
      assert format_cost(Decimal.new("0")) == "$0.0000"
    end

    test "returns $0.00 for nil" do
      assert format_cost(nil) == "$0.00"
    end

    test "returns $0.00 for non-Decimal" do
      assert format_cost("not a decimal") == "$0.00"
    end
  end

  describe "format_decimal/1" do
    test "formats Decimal with 2 decimal places" do
      assert format_decimal(Decimal.new("3.456")) == "3.46"
      assert format_decimal(Decimal.new("0")) == "0.00"
    end

    test "returns 0.00 for nil" do
      assert format_decimal(nil) == "0.00"
    end

    test "returns 0.00 for non-Decimal" do
      assert format_decimal(:other) == "0.00"
    end
  end

  describe "format_number/1" do
    test "formats millions with M suffix" do
      assert format_number(1_500_000) == "1.5M"
      assert format_number(1_000_000) == "1.0M"
    end

    test "formats thousands with K suffix" do
      assert format_number(1_500) == "1.5K"
      assert format_number(1_000) == "1.0K"
    end

    test "formats small integers as-is" do
      assert format_number(42) == "42"
      assert format_number(0) == "0"
    end

    test "returns 0 for non-integer" do
      assert format_number(nil) == "0"
    end
  end

  describe "format_percentage/2" do
    test "formats ratio as percentage" do
      assert format_percentage(1, 4) == "25.0%"
      assert format_percentage(1, 3) == "33.3%"
    end

    test "returns dash for zero denominator" do
      assert format_percentage(5, 0) == "—"
    end
  end

  describe "format_date/1" do
    test "formats DateTime" do
      assert format_date(~U[2026-02-15 12:00:00Z]) == "2026-02-15"
    end

    test "formats NaiveDateTime" do
      assert format_date(~N[2026-02-15 12:00:00]) == "2026-02-15"
    end

    test "returns dash for other values" do
      assert format_date(nil) == "—"
    end
  end
end
