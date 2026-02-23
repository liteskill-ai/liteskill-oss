# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :liteskill,
  ecto_repos: [Liteskill.Repo],
  generators: [timestamp_type: :utc_datetime]

config :liteskill, Liteskill.Repo, types: Liteskill.Repo.PostgrexTypes

# Configure the endpoint
config :liteskill, LiteskillWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LiteskillWeb.ErrorHTML, json: LiteskillWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Liteskill.PubSub,
  live_view: [signing_salt: "e8Rdk5aP"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :liteskill, Liteskill.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  liteskill: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=. --loader:.jsx=jsx),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  json_render_prompt: [
    args:
      ~w(js/json-render/generate_prompt.js --bundle --platform=node --format=esm --outfile=../priv/json_render_prompt_gen.mjs),
    cd: Path.expand("../assets", __DIR__),
    env: %{}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  liteskill: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Ueberauth for OIDC
config :ueberauth, Ueberauth,
  providers: [
    oidc: {Ueberauth.Strategy.OIDCC, []}
  ]

# Single-user mode (desktop / self-hosted). Set SINGLE_USER_MODE=true to enable.
config :liteskill, :single_user_mode, false

# Configure LLM defaults (region/token used by CohereClient for RAG embeddings)
config :liteskill, Liteskill.LLM, bedrock_region: "us-east-1"

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :liteskill, Oban,
  repo: Liteskill.Repo,
  queues: [default: 10, rag_ingest: 5, data_sync: 3, agent_runs: 3]

# Tauri desktop shell configuration
config :ex_tauri,
  version: "2.5.1",
  app_name: "Liteskill",
  host: "localhost",
  port: 4000,
  window_title: "Liteskill",
  width: 1280,
  height: 900,
  resize: true,
  fullscreen: false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
