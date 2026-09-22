defmodule MetadataAppWeb.MetaEstadoController do
  @moduledoc """
  CRUD admin de `meta_schema_estados` — arma los estados del autómata de un
  Business Context. Ejecución real de transiciones va por
  `MetadataAppWeb.MetaTransicionController`, no por acá.
  """

  use MetadataAppWeb, :controller

  alias MetadataApp.MetaEstadosAdmin

  # SPEC-SYS-2209202601 (R7, design.md §3) -- recurso fijo, mismo
  # permiso de plataforma que ya protege BC Motor/BC List en la web.
  plug MetadataAppWeb.Plugs.RequierePermiso, [recurso: "sysadmin_bc", accion: "leer"] when action in [:index]
  plug MetadataAppWeb.Plugs.RequierePermiso, [recurso: "sysadmin_bc", accion: "editar"] when action in [:create]

  action_fallback MetadataAppWeb.FallbackController

  def index(conn, %{"meta_schema_header_id" => header_id}) do
    data = header_id |> MetaEstadosAdmin.listar_estados() |> Enum.map(&estado_data/1)
    json(conn, %{data: data})
  end



  def create(conn, %{"meta_schema_estado" => attrs}) when is_list(attrs) do
    with {:ok, estados} <- MetaEstadosAdmin.crear_estados(attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: Enum.map(estados, &estado_data/1)})
    end
  end

  def create(conn, %{"meta_schema_estado" => attrs}) do
    with {:ok, estado} <- MetaEstadosAdmin.crear_estado(attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: estado_data(estado)})
    end
  end

  defp estado_data(e) do
    %{
      id: e.id,
      meta_schema_header_id: e.meta_schema_header_id,
      nombre: e.nombre,
      es_inicial: e.es_inicial,
      orden: e.orden,
      color: e.color,
      icono: e.icono
    }
  end
end
