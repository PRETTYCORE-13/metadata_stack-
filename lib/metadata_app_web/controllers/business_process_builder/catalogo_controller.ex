defmodule MetadataAppWeb.BusinessProcessBuilder.CatalogoController do
  use MetadataAppWeb, :controller
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaStateEngine

  action_fallback MetadataAppWeb.FallbackController

  # Sin estos parámetros el listado igual sale paginado (defaults acá
  # abajo) — "siempre paginado" no puede depender de que el cliente HTTP
  # se acuerde de mandar pagina/por_pagina.
  @por_pagina_default 25
  @por_pagina_maximo 100

  def index(conn, %{"tabla" => tabla} = params) do
    with {:ok, schema_mod} <- resolver(tabla) do
      {pagina, por_pagina} = resolver_paginacion(params)
      offset = (pagina - 1) * por_pagina

      items = CatalogoGenerico.listar(schema_mod, %{}, limit: por_pagina, offset: offset)
      total_filas = CatalogoGenerico.contar(schema_mod)
      meta_campos = tabla |> MetaSchemaContext.listar_detalles() |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
      estados_por_id = MetaStateEngine.mapa_nombres_estados(tabla)

      json(
        conn,
        Jason.OrderedObject.new(
          meta_campos: meta_campos,
          data: Enum.map(items, &CatalogoGenerico.serializar(&1, estados_por_id)),
          paginacion: %{
            pagina: pagina,
            por_pagina: por_pagina,
            total_filas: total_filas,
            total_paginas: total_paginas(total_filas, por_pagina)
          }
        )
      )
    end
  end

  defp resolver_paginacion(params) do
    pagina = params |> Map.get("pagina") |> parse_entero(1) |> max(1)
    por_pagina = params |> Map.get("por_pagina") |> parse_entero(@por_pagina_default) |> clamp(1, @por_pagina_maximo)
    {pagina, por_pagina}
  end

  defp parse_entero(nil, default), do: default
  defp parse_entero(valor, _default) when is_integer(valor), do: valor

  defp parse_entero(valor, default) do
    case Integer.parse(to_string(valor)) do
      {n, _resto} -> n
      :error -> default
    end
  end

  defp clamp(n, minimo, maximo), do: n |> max(minimo) |> min(maximo)

  defp total_paginas(0, _por_pagina), do: 1
  defp total_paginas(total_filas, por_pagina), do: ceil(total_filas / por_pagina)

  def show(conn, %{"tabla" => tabla, "id" => id}) do
    with {:ok, schema_mod} <- resolver(tabla) do
      item = CatalogoGenerico.obtener!(schema_mod, id)
      meta_campos = tabla |> MetaSchemaContext.listar_detalles() |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
      estados_por_id = MetaStateEngine.mapa_nombres_estados(tabla)

      json(
        conn,
        Jason.OrderedObject.new(meta_campos: meta_campos, data: CatalogoGenerico.serializar(item, estados_por_id))
      )
    end
  end

  def create(conn, %{"tabla" => tabla} = params) do
    with {:ok, schema_mod} <- resolver(tabla) do
      attrs = Map.get(params, tabla, Map.drop(params, ["tabla"]))
      estados_por_id = MetaStateEngine.mapa_nombres_estados(tabla)

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
        json(conn, %{data: CatalogoGenerico.serializar(item, MetaStateEngine.mapa_nombres_estados(tabla))})
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
