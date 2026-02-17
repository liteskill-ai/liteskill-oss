defmodule Liteskill.Aggregate do
  use Boundary, top_level?: true, deps: [Liteskill.EventStore], exports: [Loader]

  @moduledoc """
  Behaviour for event-sourced aggregates.

  Aggregates handle commands (producing events) and apply events (updating state).
  """

  @callback init() :: struct()

  @callback apply_event(state :: struct(), event :: map()) :: struct()

  @callback handle_command(state :: struct(), command :: tuple()) ::
              {:ok, [map()]} | {:error, term()}
end
