import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :liteskill, Liteskill.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "liteskill_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :liteskill, LiteskillWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "k7UgpXGIuGs58stVlRNPYmIA3Rq1+0geRNZ5XaiFSVCLqkZdWXbXcQhf71wg5U5U",
  server: false

# In test we don't send emails
config :liteskill, Liteskill.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Encryption key for sensitive fields (API keys, etc.)
config :liteskill, :encryption_key, "test-only-encryption-key-do-not-use-in-prod"

# Fast Argon2 hashing for tests
config :argon2_elixir, t_cost: 1, m_cost: 8

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :liteskill, Oban, testing: :manual

config :liteskill, Liteskill.Rag.EmbedQueue,
  max_retries: 1,
  backoff_ms: 1,
  flush_ms: 50

# Used by Application to skip ensure_admin_user Task (sandbox not available)
config :liteskill, env: :test

# Disable persistent_term cache for Settings (incompatible with Ecto sandbox)
config :liteskill, :settings_cache, false
