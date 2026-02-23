defmodule Liteskill.MixProject do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim()

  def project do
    [
      app: :liteskill,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [tool: ExCoveralls],
      releases: releases(),
      dialyzer: [
        list_unused_filters: true,
        plt_add_apps: [:ex_unit],
        excluded_paths: ["test/support"]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Liteskill.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:pgvector, "~> 0.3.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.5"},
      {:oban, "~> 2.19"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0", override: true},
      {:jason, "~> 1.2"},
      {:mdex, "~> 0.11"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_oidcc, "~> 0.4"},
      {:oidcc, "~> 3.0"},
      {:argon2_elixir, "~> 4.1"},
      {:jose, "~> 1.11"},
      {:jido, "~> 2.0.0-rc"},
      {:boundary, "~> 0.10", runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:tidewave, "~> 0.5", only: :dev},
      {:ex_tauri,
       git: "https://github.com/filipecabaco/ex_tauri.git", optional: true, runtime: false},
      {:burrito, "~> 1.5", optional: true}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: [
        "deps.get",
        "ecto.setup",
        "cmd npm install --prefix assets",
        "assets.setup",
        "gen.jr_prompt",
        "assets.build"
      ],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind liteskill", "esbuild liteskill"],
      "assets.deploy": [
        "gen.jr_prompt",
        "tailwind liteskill --minify",
        "esbuild liteskill --minify",
        "phx.digest"
      ],
      "desktop.setup": ["deps.get", "ex_tauri.install"],
      "desktop.dev": ["ex_tauri.dev"],
      "desktop.build": ["ex_tauri.build"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "sobelow --config --exit low",
        "dialyzer",
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "coveralls",
        "cmd mdbook build docs/"
      ]
    ]
  end

  defp releases do
    [
      liteskill: [
        steps: [:assemble]
      ],
      desktop: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_aarch64: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            linux_x86_64: linux_target_opts(),
            windows_x86_64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  # When BURRITO_CUSTOM_ERTS is set, use a glibc ERTS tarball instead of Burrito's
  # default musl-linked precompiled ERTS. This avoids musl/glibc symbol conflicts
  # with NIFs (MDEx, argon2) that are compiled against glibc.
  # skip_nifs: true prevents Burrito from recompiling NIFs with Zig (Linux is always
  # treated as a cross-build internally), since the NIFs from `mix compile` are
  # already glibc-linked and compatible with the custom ERTS.
  defp linux_target_opts do
    base = [os: :linux, cpu: :x86_64]

    case System.get_env("BURRITO_CUSTOM_ERTS") do
      nil -> base
      "" -> base
      path -> base ++ [custom_erts: path, skip_nifs: true]
    end
  end
end
