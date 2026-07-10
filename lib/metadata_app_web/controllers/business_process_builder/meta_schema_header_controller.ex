defmodule MetadataAppWeb.BusinessProcessBuilder.MetaSchemaHeaderController do
  use MetadataAppWeb, :controller
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerador

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
      conn
      |> put_status(:created)
      |> json(%{data: header_data(header, detalles), catalogo: generar_catalogo(header)})
    end
  end

  # En dev/test hay compilador disponible, así que el catálogo se genera y
  # migra al toque. En un release de producción no hay Mix ni compilador
  # (ver config/config.exs) — ahí solo queda guardada la metadata, y la
  # generación real corre después en el build (mix gen.catalogos).
  defp generar_catalogo(header) do
    if Application.get_env(:metadata_app, :generar_catalogos_en_caliente, false) do
      case CatalogoGenerador.generar(header.schema_context_name) do
        {:ok, %{tabla: tabla, ya_existia: true}} ->
          %{tabla: tabla, generado: false, mensaje: "el catálogo ya existía, no se tocó"}

        {:ok, %{tabla: tabla}} ->
          %{tabla: tabla, generado: true, ruta: "/api/#{tabla}"}

        {:error, mensaje} ->
          %{generado: false, error: mensaje}
      end
    else
      %{generado: false, mensaje: "metadata guardada; el catálogo se generará en el próximo build"}
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
