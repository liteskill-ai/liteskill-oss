defmodule Liteskill.Usage.CostCalculator do
  @moduledoc """
  Shared cost-resolution logic for LLM usage recording.

  Resolves costs by preferring API-reported costs, falling back to
  model rate-based calculation (cost_per_million fields on LlmModel).
  """

  @doc """
  Resolves input, output, and total costs for a usage map.

  Prefers API-reported costs (`:input_cost`, `:output_cost`, `:total_cost`
  in the usage map). Falls back to calculating from `llm_model` rates
  (`input_cost_per_million`, `output_cost_per_million`).

  Returns `{input_cost, output_cost, total_cost}` where each is a
  `Decimal` or `nil`.
  """
  def resolve_costs(usage, llm_model, input_tokens, output_tokens) do
    api_input = to_decimal(usage[:input_cost])
    api_output = to_decimal(usage[:output_cost])
    api_total = to_decimal(usage[:total_cost])

    if api_total do
      {api_input, api_output, api_total}
    else
      input_cost = cost_from_rate(input_tokens, llm_model && llm_model.input_cost_per_million)
      output_cost = cost_from_rate(output_tokens, llm_model && llm_model.output_cost_per_million)

      total_cost =
        if input_cost || output_cost do
          Decimal.add(input_cost || Decimal.new(0), output_cost || Decimal.new(0))
        end

      {input_cost, output_cost, total_cost}
    end
  end

  @doc """
  Converts a value to `Decimal`, handling `nil`, floats, integers,
  and passthrough for existing `Decimal` values.
  """
  def to_decimal(nil), do: nil
  def to_decimal(%Decimal{} = d), do: d
  def to_decimal(val) when is_float(val), do: Decimal.from_float(val)
  def to_decimal(val) when is_integer(val), do: Decimal.new(val)

  defp cost_from_rate(_tokens, nil), do: nil
  defp cost_from_rate(0, _rate), do: Decimal.new(0)

  defp cost_from_rate(tokens, rate) do
    tokens |> Decimal.new() |> Decimal.mult(rate) |> Decimal.div(1_000_000)
  end
end
