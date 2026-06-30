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
      {DNSCluster, query: Application.get_env(:metadata_app, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MetadataApp.PubSub},
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
