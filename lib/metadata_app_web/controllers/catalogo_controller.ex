defmodule MetadataAppWeb.CatalogoController do
  use MetadataAppWeb, :controller
  alias MetadataApp.CatalogoGenerico
  alias MetadataApp.MetaSchemaContext
  alias MetadataApp.StateEngine

  action_fallback MetadataAppWeb.FallbackController

  def index(conn, %{"tabla" => tabla}) do
    with {:ok, schema_mod} <- resolver(tabla) do
      items = CatalogoGenerico.listar(schema_mod)
      meta_campos = tabla |> MetaSchemaContext.listar_detalles() |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
      estados_por_id = StateEngine.mapa_nombres_estados(tabla)

      json(
        conn,
        Jason.OrderedObject.new(
          meta_campos: meta_campos,
          data: Enum.map(items, &CatalogoGenerico.serializar(&1, estados_por_id))
        )
      )
    end
  end

  def show(conn, %{"tabla" => tabla, "id" => id}) do
    with {:ok, schema_mod} <- resolver(tabla) do
      item = CatalogoGenerico.obtener!(schema_mod, id)
      meta_campos = tabla |> MetaSchemaContext.listar_detalles() |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
      estados_por_id = StateEngine.mapa_nombres_estados(tabla)

      json(
        conn,
        Jason.OrderedObject.new(meta_campos: meta_campos, data: CatalogoGenerico.serializar(item, estados_por_id))
      )
    end
  end

  def create(conn, %{"tabla" => tabla} = params) do
    with {:ok, schema_mod} <- resolver(tabla) do
      attrs = Map.get(params, tabla, Map.drop(params, ["tabla"]))
      estados_por_id = StateEngine.mapa_nombres_estados(tabla)

      if is_list(attrs) do
        with {:ok, items} <- CatalogoGenerico.crear_muchos(schema_mod, attrs) do
          conn
          |> put_status(:created)
          |> json(%{data: Enum.map(items, &CatalogoGenerico.serializar(&1, estados_por_id))})
        end
      else
        with {:ok, item} <- CatalogoGenerico.crear(schema_mod, attrs) do
          conn
          |> put_status(:created)
          |> json(%{data: CatalogoGenerico.serializar(item, estados_por_id)})
        end
      end
    end
  end

  def update(conn, %{"tabla" => tabla, "id" => id} = params) do
    with {:ok, schema_mod} <- resolver(tabla) do
      attrs = Map.get(params, tabla, Map.drop(params, ["tabla", "id"]))
      item = CatalogoGenerico.obtener!(schema_mod, id)

      with {:ok, item} <- CatalogoGenerico.actualizar(item, attrs) do
        json(conn, %{data: CatalogoGenerico.serializar(item, StateEngine.mapa_nombres_estados(tabla))})
      end
    end
  end

  def delete(conn, %{"tabla" => tabla, "id" => id}) do
    with {:ok, schema_mod} <- resolver(tabla) do
      item = CatalogoGenerico.obtener!(schema_mod, id)

      with {:ok, _item} <- CatalogoGenerico.eliminar(item) do
        send_resp(conn, :no_content, "")
      end
    end
  end

  defp resolver(tabla) do
    case MetaSchemaContext.modulo_por_nombre(tabla) do
      nil -> {:error, :not_found}
      modulo -> {:ok, modulo}
    end
  end
end
