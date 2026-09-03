defmodule FluxVale.MixProject do
  use Mix.Project

  def project do
    [
      app: :flux_vale,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      # v1 port: PLT in priv/plts (gitignored), exact-version CI cache key
      dialyzer: [
        plt_add_apps: [:ex_unit],
        plt_file: {:no_warn, "priv/plts/project.plt"},
        list_unused_filters: true
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {FluxVale.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, ci: :test]
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
      # Every Hex dep is exact-pinned from mix.lock (codified in AGENTS.md):
      # bumps to behavior-bearing libraries — auth, policies, the linter that
      # gates CI — must be deliberate diffs, never a side effect of
      # deps.update. GitHub deps (heroicons, daisyui) stay tag-pinned.
      # SimpleSat over Picosat: pure-Elixir SAT solver — picosat_elixir is a
      # C NIF that won't compile against musl (alpine dev image,
      # sys/unistd.h is a glibc-ism). Crux auto-selects SimpleSat when Picosat
      # isn't loaded. Revisit trigger: policy-SAT cost shows up in profiles —
      # then Picosat on a glibc base, deliberately.
      {:simple_sat, "0.1.4"},
      {:ash_authentication, "4.14.2"},
      # Dev/test-only analysis tools (exact pins, same rule)
      {:dialyxir, "1.4.7", only: [:dev, :test], runtime: false},
      {:credo, "1.7.19", only: [:dev, :test], runtime: false},
      {:open_api_spex, "3.22.4"},
      {:ash_json_api, "1.7.1"},
      {:ash_admin, "1.3.1"},
      {:ash_postgres, "2.13.0"},
      {:ash_phoenix, "2.3.25"},
      {:igniter, "0.8.3", only: [:dev, :test]},
      {:phoenix, "1.8.13"},
      {:phoenix_ecto, "4.7.0"},
      {:ecto_sql, "3.14.0"},
      {:postgrex, "0.22.4"},
      {:phoenix_html, "4.3.0"},
      {:phoenix_live_reload, "1.7.0", only: :dev},
      {:phoenix_live_view, "1.2.11"},
      {:lazy_html, "0.1.12", only: :test},
      {:phoenix_live_dashboard, "0.8.7"},
      {:esbuild, "0.10.0", runtime: Mix.env() == :dev},
      {:tailwind, "0.5.1", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "1.28.0"},
      {:req, "0.7.4"},
      {:telemetry_metrics, "1.2.0"},
      {:telemetry_poller, "1.3.0"},
      {:gettext, "1.0.2"},
      {:jason, "1.4.5"},
      {:dns_cluster, "0.2.0"},
      {:bandit, "1.12.5"}
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
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind flux_vale", "esbuild flux_vale"],
      "assets.deploy": [
        "tailwind flux_vale --minify",
        "esbuild flux_vale --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      # CI-grade gate: everything a PR must pass, in one command (#5).
      # Dialyzer joins credo: Specs enforcement (presence) + dialyzer
      # (correctness) are the two halves of the typespec story.
      ci: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end
end
