# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :metadata_app,
  ecto_repos: [MetadataApp.Repo],
  generators: [timestamp_type: :utc_datetime]

# Nombre de la tabla de control de migraciones de Ecto — se alinea al
# estándar meta_schema_* del resto del proyecto en vez del default
# "schema_migrations".
config :metadata_app, MetadataApp.Repo,
  migration_source: "meta_schema_migrations"

# Generar el catálogo (migración + schema + compilar) en el momento del POST
# solo tiene sentido donde hay compilador disponible (dev/test). En un
# release de producción no hay Mix ni compilador, así que ahí el endpoint
# solo guarda la metadata y la generación real pasa a correr en el build
# (mix gen.catalogos). Se resuelve acá, en config, para no llamar Mix.env()
# en tiempo de ejecución — eso rompería en un release compilado.
config :metadata_app, generar_catalogos_en_caliente: Mix.env() != :prod

# Local (dev/test) usa el BPB para construir y probar catálogos.
# Producción detecta que es un deploy real y lo deshabilita del todo — ni
# rutas ni links visibles — porque ahí no hay compilador (mismo motivo que
# generar_catalogos_en_caliente de arriba), y porque un usuario de negocio
# en producción no tiene nada que hacer en la herramienta de construcción.
# Concepto separado a propósito, aunque hoy tenga el mismo valor: son dos
# decisiones de diseño distintas, ver docs/upcoming-features.md #7.
config :metadata_app, bpb_habilitado: Mix.env() != :prod

# Configures the endpoint
config :metadata_app, MetadataAppWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MetadataAppWeb.ErrorHTML, json: MetadataAppWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MetadataApp.PubSub,
  live_view: [signing_salt: "UOwnCDHa"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :metadata_app, MetadataApp.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  metadata_app: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  metadata_app: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
