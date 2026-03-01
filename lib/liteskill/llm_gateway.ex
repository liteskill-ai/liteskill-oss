defmodule Liteskill.LlmGateway do
  @moduledoc """
  Rate limiting and circuit-breaking gateway for outbound LLM calls.

  Two-tier approach:
  - **TokenBucket**: Per-user+model ETS-based rate limiter (lock-free)
  - **ProviderGate**: Per-provider GenServer with circuit breaker + concurrency cap

  Orthogonal to `Liteskill.LLM` (which handles streaming/events).
  """
  use Boundary,
    top_level?: true,
    deps: [Liteskill.LlmModels, Liteskill.LlmProviders],
    exports: [TokenBucket, ProviderGate]
end
