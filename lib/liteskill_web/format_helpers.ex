defmodule LiteskillWeb.FormatHelpers do
  @moduledoc """
  Shared formatting helpers for costs, tokens, numbers, and dates.

  Used across AdminLive, ChatLive, and AgentStudioComponents.
  Import this module in any view/component that needs these formatters.
  """

  @doc "Formats a Decimal cost as a dollar string with 4 decimal places."
  def format_cost(nil), do: "$0.00"
  def format_cost(%Decimal{} = d), do: "$#{Decimal.round(d, 4)}"
  def format_cost(_), do: "$0.00"

  @doc "Formats a Decimal value with 2 decimal places (no dollar sign)."
  def format_decimal(nil), do: "0.00"
  def format_decimal(%Decimal{} = d), do: Decimal.to_string(Decimal.round(d, 2))
  def format_decimal(_), do: "0.00"

  @doc "Formats a large integer with K/M suffixes."
  def format_number(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"

  def format_number(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"

  def format_number(n) when is_integer(n), do: Integer.to_string(n)
  def format_number(_), do: "0"

  @doc "Formats a ratio as a percentage string."
  def format_percentage(_, 0), do: "—"
  def format_percentage(part, whole), do: "#{Float.round(part / whole * 100, 1)}%"

  @doc "Formats a DateTime or NaiveDateTime as YYYY-MM-DD."
  def format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  def format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  def format_date(_), do: "—"
end
