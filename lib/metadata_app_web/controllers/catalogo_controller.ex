defmodule MetadataAppWeb.CatalogoController do
  use MetadataAppWeb, :controller
  alias MetadataApp.CatalogoGenerico
  alias MetadataApp.CatalogoRegistry
  alias MetadataApp.MetaModelContext

  action_fallback MetadataAppWeb.FallbackController

  def index(conn, %{"tabla" => tabla}) do
    with {:ok, schema_mod, schema_nombre} <- resolver(tabla) do
      items = CatalogoGenerico.listar(schema_mod)
      meta_campos = schema_nombre |> MetaModelContext.listar_campos() |> Enum.map(&MetaModelContext.serializar_campo/1)

      json(
        conn,
        Jason.OrderedObject.new(
          meta_campos: meta_campos,
          data: Enum.map(items, &CatalogoGenerico.serializar/1)
        )
      )
    end
  end

  def show(conn, %{"tabla" => tabla, "id" => id}) do
    with {:ok, schema_mod, schema_nombre} <- resolver(tabla) do
      item = CatalogoGenerico.obtener!(schema_mod, id)
      meta_campos = schema_nombre |> MetaModelContext.listar_campos() |> Enum.map(&MetaModelContext.serializar_campo/1)

      json(
        conn,
        Jason.OrderedObject.new(meta_campos: meta_campos, data: CatalogoGenerico.serializar(item))
      )
    end
  end

  def create(conn, %{"tabla" => tabla} = params) do
    with {:ok, schema_mod, schema_nombre} <- resolver(tabla) do
      attrs = Map.get(params, schema_nombre, Map.drop(params, ["tabla"]))

      if is_list(attrs) do
        with {:ok, items} <- CatalogoGenerico.crear_muchos(schema_mod, attrs) do
          conn
          |> put_status(:created)
          |> json(%{data: Enum.map(items, &CatalogoGenerico.serializar/1)})
        end
      else
        with {:ok, item} <- CatalogoGenerico.crear(schema_mod, attrs) do
          conn
          |> put_status(:created)
          |> json(%{data: CatalogoGenerico.serializar(item)})
        end
      end
    end
  end

  def update(conn, %{"tabla" => tabla, "id" => id} = params) do
    with {:ok, schema_mod, schema_nombre} <- resolver(tabla) do
      attrs = Map.get(params, schema_nombre, Map.drop(params, ["tabla", "id"]))
      item = CatalogoGenerico.obtener!(schema_mod, id)

      with {:ok, item} <- CatalogoGenerico.actualizar(item, attrs) do
        json(conn, %{data: CatalogoGenerico.serializar(item)})
      end
    end
  end

  def delete(conn, %{"tabla" => tabla, "id" => id}) do
    with {:ok, schema_mod, _schema_nombre} <- resolver(tabla) do
      item = CatalogoGenerico.obtener!(schema_mod, id)

      with {:ok, _item} <- CatalogoGenerico.eliminar(item) do
        send_resp(conn, :no_content, "")
      end
    end
  end

  defp resolver(tabla) do
    case CatalogoRegistry.obtener_por_tabla(tabla) do
      nil -> {:error, :not_found}
      catalogo -> {:ok, CatalogoRegistry.modulo_por_tabla(tabla), catalogo.schema_nombre}
    end
  end
end
