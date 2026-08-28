defmodule MetadataApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :metadata_app,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: dialyzer()
    ]
  end

  # Fase 5 del modelo de Alcance de Datos (2026-08-11) — PLT en
  # priv/plts (no en _build, que mix clean puede borrar) para no
  # reconstruirlo desde cero cada vez. plt_add_apps: :ecto porque las
  # specs nuevas de CatalogoGenerico usan Ecto.Query.t() en sus tipos.
  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:ecto, :ex_unit]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {MetadataApp.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
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
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
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
      {:gen_smtp, "~> 1.0"},
      {:pbkdf2_elixir, "~> 2.0"},
      {:req, "~> 0.5"},
      {:cloak_ecto, "~> 1.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:ulid, "~> 0.2.0"},
      # Módulo de Importación de Datos (Fase 1, 2026-08-27) — puro
      # Elixir/BEAM, sin compilación nativa/Rust (a diferencia de
      # umya_spreadsheet, que necesita el toolchain de Rust — riesgo real
      # en esta máquina Windows, que ya tuvo fricción con symlinks/
      # permisos de Phoenix). elixlsx genera la plantilla descargable
      # (multi-hoja); xlsxir lee el archivo que el usuario sube.
      {:elixlsx, "~> 0.6"},
      {:xlsxir, "~> 1.6"},
      # Fase 5 del modelo de Alcance de Datos (2026-08-11) — guardrails
      # estructurales: Credo (check custom que prohíbe Repo.* directo
      # fuera de CatalogoGenerico) + Dialyzer (typespecs de Scope/scope
      # obligatorio ya agregados en CatalogoGenerico).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: :test}
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
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind metadata_app", "esbuild metadata_app"],
      "assets.deploy": [
        "tailwind metadata_app --minify",
        "esbuild metadata_app --minify",
        "phx.digest"
      ],
      # Fase 5 del modelo de Alcance de Datos (2026-08-11) — check acotado
      # a MetadataApp.CredoChecks.RepoDirectoConVariable, NO `credo --strict`
      # completo: el repo tiene ~460 issues preexistentes de estilo/diseño
      # sin relación (line-endings, nesting, etc.) que agregar acá
      # bloquearía a todo el equipo por deuda técnica ajena a este
      # guardrail. Corre en ~0.3s, hoy en cero hallazgos.
      "credo.alcance": ["credo suggest --strict --only MetadataApp.CredoChecks.RepoDirectoConVariable"],
      precommit: [
        "compile --warning-as-errors",
        "deps.unlock --unused",
        "format",
        "credo.alcance",
        "test"
      ]
    ]
  end
end
