# Supervision Tree

Liteskill uses a `rest_for_one` supervision strategy. If an infrastructure child (like Repo or PubSub) crashes, all children started after it restart too, re-establishing subscriptions and connections.

## Child Process Order

The supervision tree starts children in this order:

1. **`LiteskillWeb.Telemetry`** — Telemetry metrics and poller
2. **`Liteskill.Desktop.PostgresManager`** — (Desktop mode only) Starts bundled PostgreSQL
3. **`Liteskill.Repo`** — Ecto repository / database connection pool
4. **`DNSCluster`** — DNS-based node clustering
5. **`Phoenix.PubSub`** — PubSub server (`Liteskill.PubSub`)
6. **`Liteskill.Rag.EmbedQueue`** — Embedding request queue (skipped in test)
7. **`Oban`** — Background job processing (queues: `default`, `rag_ingest`, `data_sync`, `agent_runs`)
8. **Boot tasks** — (non-test) Ensures admin user, system roles, env providers, and settings; auto-provisions admin in single-user mode
9. **`Liteskill.OpenRouter.StateStore`** — OAuth PKCE state storage for OpenRouter
10. **`LiteskillWeb.Plugs.RateLimiter.Sweeper`** — Periodic ETS cleanup for rate limiter
11. **`Task.Supervisor`** (`Liteskill.TaskSupervisor`) — For LLM streaming and async work
12. **`Liteskill.Chat.StreamRegistry`** — Monitors active LLM stream tasks, triggers recovery on crash
13. **`Registry`** (`Liteskill.LlmGateway.GateRegistry`) — Per-provider gate registry
14. **`DynamicSupervisor`** (`Liteskill.LlmGateway.GateSupervisor`) — Dynamic circuit breaker gates
15. **`Liteskill.LlmGateway.TokenBucket.Sweeper`** — Periodic ETS cleanup for token buckets
16. **`Liteskill.Chat.Projector`** — Event → projection table updater
17. **`Liteskill.Chat.StreamRecovery`** — Periodic sweep for stuck streaming conversations
18. **`Liteskill.Schedules.ScheduleTick`** — (non-test) Periodic check for due schedules
19. **`LiteskillWeb.Endpoint`** — Phoenix HTTP endpoint (started last)

## LLM Gateway

The LLM Gateway provides per-provider concurrency control and circuit breaking:

- **`GateRegistry`** — Unique registry keyed by provider ID
- **`GateSupervisor`** — Dynamically spawns `Gate` processes per provider
- **`TokenBucket`** — ETS-based rate limiting with periodic sweeper

## Stream Registry

`Liteskill.Chat.StreamRegistry` monitors active LLM streaming tasks. If a streaming task crashes, the registry detects the `:DOWN` message and triggers stream recovery, preventing conversations from getting stuck in the `:streaming` state.

## Stream Recovery

`Liteskill.Chat.StreamRecovery` is a periodic sweeper that detects conversations stuck in streaming state for more than 5 minutes and automatically recovers them by failing the stream.
