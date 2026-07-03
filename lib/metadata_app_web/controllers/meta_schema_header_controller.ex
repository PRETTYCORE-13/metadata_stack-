defmodule MetadataAppWeb.MetaSchemaHeaderController do
  use MetadataAppWeb, :controller
  alias MetadataApp.MetaSchemaContext
  alias MetadataApp.CatalogoGenerador

  action_fallback MetadataAppWeb.FallbackController

  def index(conn, _params) do
    headers = MetaSchemaContext.listar_headers()
    json(conn, %{data: Enum.map(headers, &header_data/1)})
  end

  def show(conn, %{"id" => id}) do
    header = MetaSchemaContext.obtener_header!(id)
    detalles = MetaSchemaContext.listar_detalles(header.schema_context_name)

    json(conn, %{data: header_data(header, detalles)})
  end

  def create(conn, %{"meta_schema_header" => header_attrs}) do
    with {:ok, {header, detalles}} <- MetaSchemaContext.crear_header_con_detalles(header_attrs) do
      catalogo =
        case CatalogoGenerador.generar(header.schema_context_name) do
          {:ok, %{tabla: tabla, ya_existia: true}} ->
            %{tabla: tabla, generado: false, mensaje: "el catálogo ya existía, no se tocó"}

          {:ok, %{tabla: tabla}} ->
            %{tabla: tabla, generado: true, ruta: "/api/#{tabla}"}

          {:error, mensaje} ->
            %{generado: false, error: mensaje}
        end

      conn
      |> put_status(:created)
      |> json(%{data: header_data(header, detalles), catalogo: catalogo})
    end
  end

  def update(conn, %{"id" => id, "meta_schema_header" => attrs}) do
    header = MetaSchemaContext.obtener_header!(id)

    with {:ok, header} <- MetaSchemaContext.actualizar_header(header, attrs) do
      json(conn, %{data: header_data(header)})
    end
  end

  defp header_data(header, detalles \\ nil) do
    base = %{
      id: header.id,
      schema_context_name: header.schema_context_name,
      schema_context_label: header.schema_context_label,
      schema_context_type: header.schema_context_type,
      schema_context_nav: header.schema_context_nav,
      schema_visible: header.schema_visible,
      schema_set_permissions: header.schema_set_permissions,
      schema_profiles: header.schema_profiles
    }

    case detalles do
      nil -> base
      detalles -> Map.put(base, :detalles, Enum.map(detalles, &MetaSchemaContext.serializar_detalle/1))
    end
  end
end
