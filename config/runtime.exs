import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/liteskill start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :liteskill, LiteskillWeb.Endpoint, server: true
end

config :liteskill, LiteskillWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# OIDC configuration (all environments)
if System.get_env("OIDC_CLIENT_ID") do
  config :ueberauth, Ueberauth.Strategy.OIDCC,
    issuer: System.get_env("OIDC_ISSUER"),
    client_id: System.get_env("OIDC_CLIENT_ID"),
    client_secret: System.get_env("OIDC_CLIENT_SECRET")
end

# SAML configuration (all environments)
if saml_metadata_file = System.get_env("SAML_IDP_METADATA_FILE") do
  saml_sp_id = System.get_env("SAML_SP_ID", "liteskill")
  saml_sp_entity_id = System.get_env("SAML_SP_ENTITY_ID", "urn:liteskill:sp")
  saml_sp_certfile = System.get_env("SAML_SP_CERTFILE", "")
  saml_sp_keyfile = System.get_env("SAML_SP_KEYFILE", "")
  saml_idp_id = System.get_env("SAML_IDP_ID", "saml")

  port = String.to_integer(System.get_env("PORT", "4000"))
  host = System.get_env("PHX_HOST", "localhost")
  scheme = if System.get_env("PHX_SERVER"), do: "https", else: "http"
  saml_base_url = System.get_env("SAML_BASE_URL", "#{scheme}://#{host}:#{port}/sso")

  config :liteskill, :saml_configured, true

  config :samly, Samly.Provider,
    idp_id_from: :path_segment,
    service_providers: [
      %{
        id: saml_sp_id,
        entity_id: saml_sp_entity_id,
        certfile: saml_sp_certfile,
        keyfile: saml_sp_keyfile
      }
    ],
    identity_providers: [
      %{
        id: saml_idp_id,
        sp_id: saml_sp_id,
        base_url: saml_base_url,
        metadata_file: saml_metadata_file,
        pre_session_create_pipeline: LiteskillWeb.SamlPipeline,
        sign_requests: true,
        sign_metadata: true,
        signed_assertion_in_resp: true,
        signed_envelopes_in_resp: true
      }
    ]
end

# AWS Bedrock configuration (all environments)
bedrock_overrides =
  [
    {System.get_env("AWS_BEARER_TOKEN_BEDROCK"), :bedrock_bearer_token},
    {System.get_env("AWS_REGION"), :bedrock_region}
  ]
  |> Enum.reject(fn {val, _key} -> is_nil(val) end)
  |> Enum.map(fn {val, key} -> {key, val} end)

# ReqLLM connection pool — increase default Finch pool size for LLM concurrency.
# Key must be :finch (not :finch_options) — that's what ReqLLM.Application reads.
#
# Timeouts: stream_receive_timeout controls the idle timeout between streaming chunks
# (including time-to-first-token after sending a large context). Default 30s is too
# short for tool-calling rounds where the LLM must process prior tool inputs/outputs.
config :req_llm,
  stream_receive_timeout: 120_000,
  receive_timeout: 120_000,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http1], size: 25, count: 1]
    }
  ]

if bedrock_overrides != [] do
  existing = Application.get_env(:liteskill, Liteskill.LLM, [])
  config :liteskill, Liteskill.LLM, Keyword.merge(existing, bedrock_overrides)
end

# Single-user mode (desktop / self-hosted)
if System.get_env("SINGLE_USER_MODE") in ~w(true 1 yes) do
  config :liteskill, :single_user_mode, true
end

# Server-side session timeouts (seconds)
if max_age = System.get_env("SESSION_MAX_AGE_SECONDS") do
  config :liteskill, :session_max_age_seconds, String.to_integer(max_age)
end

if idle_timeout = System.get_env("SESSION_IDLE_TIMEOUT_SECONDS") do
  config :liteskill, :session_idle_timeout_seconds, String.to_integer(idle_timeout)
end

# Encryption is off by default. Set LITESKILL_ENCRYPTION=true to enable.
encryption_enabled? = System.get_env("LITESKILL_ENCRYPTION") in ~w(true 1 yes)

# Desktop mode: bundled PostgreSQL, single-user, no external dependencies
if System.get_env("LITESKILL_DESKTOP") == "true" do
  desktop_data_dir =
    case :os.type() do
      {:unix, :darwin} ->
        Path.join(System.get_env("HOME", "~"), "Library/Application Support/Liteskill")

      {:unix, _} ->
        xdg =
          System.get_env("XDG_DATA_HOME", Path.join(System.get_env("HOME", "~"), ".local/share"))

        Path.join(xdg, "liteskill")

      {:win32, _} ->
        Path.join(System.get_env("APPDATA", "C:/Users/Default/AppData/Roaming"), "Liteskill")
    end

  # NOTE: This config creation logic is intentionally duplicated from
  # Liteskill.Desktop.load_or_create_config!/1 because runtime.exs executes
  # before application code is available in releases. If you change the key
  # structure here, update Desktop.load_or_create_config!/1 to match.
  desktop_config_path = Path.join(desktop_data_dir, "desktop_config.json")

  desktop_config =
    if File.exists?(desktop_config_path) do
      desktop_config_path |> File.read!() |> Jason.decode!()
    else
      cfg = %{
        "secret_key_base" => Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
      }

      File.mkdir_p!(desktop_data_dir)
      File.write!(desktop_config_path, Jason.encode!(cfg, pretty: true))
      cfg
    end

  config :liteskill, :desktop_data_dir, desktop_data_dir
  config :liteskill, :desktop_mode, true
  config :liteskill, :single_user_mode, true

  # Encryption is opt-in. Desktop configs from older installs may have an
  # encryption_key — it is only used when LITESKILL_ENCRYPTION=true.
  if encryption_enabled? do
    encryption_key =
      System.get_env("ENCRYPTION_KEY") || desktop_config["encryption_key"] ||
        raise "LITESKILL_ENCRYPTION=true requires ENCRYPTION_KEY env var or key in desktop_config.json"

    config :liteskill, :encryption_key, encryption_key
  end

  repo_opts =
    case :os.type() do
      {:win32, _} ->
        pg_port = String.to_integer(System.get_env("LITESKILL_PG_PORT", "15432"))
        config :liteskill, :desktop_pg_port, pg_port

        [database: "liteskill_desktop", hostname: "localhost", port: pg_port, pool_size: 5]

      _ ->
        socket_dir = Path.join(desktop_data_dir, "pg_socket")
        [database: "liteskill_desktop", socket_dir: socket_dir, pool_size: 5]
    end

  port = String.to_integer(System.get_env("PORT", "4000"))

  config :liteskill, Liteskill.Repo, repo_opts

  config :liteskill, LiteskillWeb.Endpoint,
    url: [host: "localhost", port: port, scheme: "http"],
    http: [ip: {127, 0, 0, 1}, port: port],
    server: true,
    check_origin: false,
    secret_key_base: desktop_config["secret_key_base"]

  config :liteskill, :dns_cluster_query, nil
end

if config_env() == :test do
  database_url =
    System.get_env("DATABASE_URL") ||
      "ecto://postgres:postgres@localhost/liteskill_test#{System.get_env("MIX_TEST_PARTITION", "")}"

  config :liteskill, Liteskill.Repo,
    url: database_url,
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2
end

if config_env() == :prod and System.get_env("LITESKILL_DESKTOP") != "true" do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # --- Auto-generate secret_key_base ---
  # Priority: env var → secrets file → generate & persist.
  # NOTE: This logic is intentionally inline because runtime.exs executes
  # before application code is available in releases.
  secrets_dir =
    if secrets_file = System.get_env("LITESKILL_SECRETS_FILE") do
      Path.dirname(secrets_file)
    else
      case :os.type() do
        {:unix, :darwin} ->
          Path.join(System.get_env("HOME", "~"), "Library/Application Support/Liteskill")

        {:unix, _} ->
          xdg =
            System.get_env("XDG_DATA_HOME", Path.join(System.get_env("HOME", "~"), ".local/share"))

          Path.join(xdg, "liteskill")

        {:win32, _} ->
          Path.join(System.get_env("APPDATA", "C:/Users/Default/AppData/Roaming"), "Liteskill")
      end
    end

  secrets_path = System.get_env("LITESKILL_SECRETS_FILE") || Path.join(secrets_dir, "secrets.json")

  saved_secrets =
    if File.exists?(secrets_path) do
      secrets_path |> File.read!() |> Jason.decode!()
    else
      secrets = %{
        "secret_key_base" => Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
      }

      File.mkdir_p!(Path.dirname(secrets_path))
      File.write!(secrets_path, Jason.encode!(secrets, pretty: true))
      secrets
    end

  secret_key_base =
    case System.get_env("SECRET_KEY_BASE") do
      nil -> saved_secrets["secret_key_base"]
      "" -> saved_secrets["secret_key_base"]
      val -> val
    end

  if encryption_enabled? do
    encryption_key =
      System.get_env("ENCRYPTION_KEY") ||
        raise "LITESKILL_ENCRYPTION=true requires ENCRYPTION_KEY env var to be set"

    config :liteskill, :encryption_key, encryption_key
  end

  host = System.get_env("PHX_HOST") || "example.com"

  config :liteskill, Liteskill.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  config :liteskill, LiteskillWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :liteskill, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :liteskill, LiteskillWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :liteskill, LiteskillWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :liteskill, Liteskill.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
