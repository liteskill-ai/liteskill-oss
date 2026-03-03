defmodule Liteskill.Usage.CostCalculatorTest do
  use ExUnit.Case, async: true

  alias Liteskill.Usage.CostCalculator

  describe "to_decimal/1" do
    test "returns nil for nil" do
      assert CostCalculator.to_decimal(nil) == nil
    end

    test "passes through Decimal values" do
      d = Decimal.new("3.14")
      assert CostCalculator.to_decimal(d) == d
    end

    test "converts floats" do
      result = CostCalculator.to_decimal(0.5)
      assert Decimal.equal?(result, Decimal.from_float(0.5))
    end

    test "converts integers" do
      assert CostCalculator.to_decimal(42) == Decimal.new(42)
    end
  end

  describe "resolve_costs/4" do
    test "prefers API-reported costs when total_cost is present" do
      usage = %{
        input_cost: 0.001,
        output_cost: 0.002,
        total_cost: 0.003
      }

      {input, output, total} = CostCalculator.resolve_costs(usage, nil, 100, 50)

      assert Decimal.equal?(total, Decimal.from_float(0.003))
      assert Decimal.equal?(input, Decimal.from_float(0.001))
      assert Decimal.equal?(output, Decimal.from_float(0.002))
    end

    test "calculates from model rates when no API costs" do
      llm_model = %{
        input_cost_per_million: Decimal.new("3"),
        output_cost_per_million: Decimal.new("15")
      }

      {input, output, total} = CostCalculator.resolve_costs(%{}, llm_model, 1_000_000, 500_000)

      assert Decimal.equal?(input, Decimal.new("3"))
      assert Decimal.equal?(output, Decimal.new("7.5"))
      assert Decimal.equal?(total, Decimal.new("10.5"))
    end

    test "returns nil costs when no API costs and no model rates" do
      {input, output, total} = CostCalculator.resolve_costs(%{}, nil, 100, 50)

      assert input == nil
      assert output == nil
      assert total == nil
    end

    test "handles zero tokens with model rates" do
      llm_model = %{
        input_cost_per_million: Decimal.new("3"),
        output_cost_per_million: Decimal.new("15")
      }

      {input, output, total} = CostCalculator.resolve_costs(%{}, llm_model, 0, 0)

      assert Decimal.equal?(input, Decimal.new(0))
      assert Decimal.equal?(output, Decimal.new(0))
      assert Decimal.equal?(total, Decimal.new(0))
    end

    test "handles partial model rates (only input)" do
      llm_model = %{
        input_cost_per_million: Decimal.new("3"),
        output_cost_per_million: nil
      }

      {input, output, total} = CostCalculator.resolve_costs(%{}, llm_model, 1_000_000, 500_000)

      assert Decimal.equal?(input, Decimal.new("3"))
      assert output == nil
      assert Decimal.equal?(total, Decimal.new("3"))
    end

    test "handles nil llm_model" do
      {input, output, total} = CostCalculator.resolve_costs(%{}, nil, 100, 50)

      assert input == nil
      assert output == nil
      assert total == nil
    end
  end
end
