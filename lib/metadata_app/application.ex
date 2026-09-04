defmodule MetadataApp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MetadataAppWeb.Telemetry,
      MetadataApp.Repo,
      MetadataApp.Vault,
      {DNSCluster, query: Application.get_env(:metadata_app, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MetadataApp.PubSub},
      # Efectos de cortesía (Paso 5b) del Motor de Estados: notificaciones y
      # similares, despachadas fuera de la transacción, sin reintentos.
      {Task.Supervisor, name: MetadataApp.MetaStateEngine.TaskSupervisor},
      # Dueño de la tabla ETS de permisos efectivos (RBAC) — separado del
      # proceso que consulta para que la cache sobreviva su muerte.
      MetadataApp.Permissions.Cache,
      # Idem, para los agregados (SUM/COUNT/AVG/MIN/MAX) que Formula
      # calcula sobre otro catálogo dentro de un "campo_calculado" — sin
      # esto, cada tecla tipeada en la Ficha 360° dispara un recorrido
      # completo del catálogo referenciado, tenga o no que ver con lo que
      # se está tipeando.
      MetadataApp.MetaPlantillas.FormulaCache,
      # Límite de intentos fallidos de /api/movil/login|verificar
      # (SPEC-API-0409202601, R10/R11) -- mismo criterio que las cachés
      # de arriba, tabla ETS en su propio proceso.
      MetadataApp.Autenticacion.LimiteIntentos,
      # Start a worker by calling: MetadataApp.Worker.start_link(arg)
      # {MetadataApp.Worker, arg},
      # Start to serve requests, typically the last entry
      MetadataAppWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MetadataApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MetadataAppWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
