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

  # Filtros por query string (ej. GET /api/pty_pedido_det?encabezado_id=123
  # para "todos los renglones de un pedido puntual") — antes no existían en
  # la API pública: index/2 siempre mandaba filtros: %{} a CatalogoGenerico,
  # aunque el mecanismo ya existe adentro (lo usa CatalogoLive). Solo
  # igualdad exacta (nada de rangos/ilike acá, eso queda para la UI admin)
  # — alcanza para el caso real (encabezado_id, estado_id, o cualquier
  # campo de negocio puntual).
  def index(conn, %{"tabla" => tabla} = params) do
    with {:ok, schema_mod} <- resolver(tabla) do
      {pagina, por_pagina} = resolver_paginacion(params)
      offset = (pagina - 1) * por_pagina
      filtros = filtros_desde_params(tabla, params)

      items = CatalogoGenerico.listar(schema_mod, filtros, limit: por_pagina, offset: offset)
      total_filas = CatalogoGenerico.contar(schema_mod, filtros)
      meta_campos = tabla |> MetaSchemaContext.listar_detalles() |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
      estados_por_id = MetaStateEngine.mapa_nombres_estados(tabla)

      json(
        conn,
        Jason.OrderedObject.new(
          [meta_campos: meta_campos] ++
            meta_campos_detalle_extra(tabla) ++
            [
              data: Enum.map(items, &serializar_json(&1, estados_por_id)),
              paginacion: %{
                pagina: pagina,
                por_pagina: por_pagina,
                total_filas: total_filas,
                total_paginas: total_paginas(total_filas, por_pagina)
              }
            ]
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

  # Cualquier query param que coincida con un campo real (de sistema o de
  # negocio) del catálogo se aplica como filtro de igualdad exacta —
  # cualquier otro param se ignora en silencio (mismo criterio REST de
  # siempre: params extra no reconocidos no son un error). Convierte al
  # tipo real de la columna para que Ecto no falle comparando un string
  # contra una columna integer/decimal/boolean.
  defp filtros_desde_params(tabla, params) do
    tipos = tipos_por_campo(tabla)

    params
    |> Map.drop(["tabla", "pagina", "por_pagina"])
    |> Enum.reduce(%{}, fn {campo, valor}, acc ->
      case Map.fetch(tipos, campo) do
        {:ok, tipo} -> Map.put(acc, campo, convertir_filtro(valor, tipo))
        :error -> acc
      end
    end)
  end

  # Campos de sistema (fuera de meta_schema_detail, ver estado_id/trn/ulid
  # y encabezado_id/renglon_id del Catálogo Maestro-Detalle) + los campos
  # de negocio del catálogo, con su tipo real.
  defp tipos_por_campo(tabla) do
    sistema = %{"id" => "integer", "encabezado_id" => "integer", "renglon_id" => "integer", "estado_id" => "integer"}
    negocio = tabla |> MetaSchemaContext.listar_detalles() |> Map.new(&{&1.schema_context_field, &1.schema_context_properties["tipo"]})
    Map.merge(sistema, negocio)
  end

  defp convertir_filtro(valor, tipo) when tipo in ["integer", "referencia"] do
    case Integer.parse(valor) do
      {n, ""} -> n
      _ -> valor
    end
  end

  defp convertir_filtro(valor, "decimal") do
    case Decimal.parse(valor) do
      {d, ""} -> d
      _ -> valor
    end
  end

  defp convertir_filtro(valor, "boolean"), do: valor in ["true", "1"]
  defp convertir_filtro(valor, _tipo), do: valor

  defp total_paginas(0, _por_pagina), do: 1
  defp total_paginas(total_filas, por_pagina), do: ceil(total_filas / por_pagina)

  def show(conn, %{"tabla" => tabla, "id" => id}) do
    with {:ok, schema_mod} <- resolver(tabla) do
      item = CatalogoGenerico.obtener!(schema_mod, id)
      meta_campos = tabla |> MetaSchemaContext.listar_detalles() |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
      estados_por_id = MetaStateEngine.mapa_nombres_estados(tabla)

      json(
        conn,
        Jason.OrderedObject.new(
          [meta_campos: meta_campos] ++ meta_campos_detalle_extra(tabla) ++ [data: serializar_json(item, estados_por_id)]
        )
      )
    end
  end

  # Fase 4, R10: solo agrega la llave "meta_campos_detalle" cuando el
  # catálogo de verdad tiene detalles — un catálogo normal (la enorme
  # mayoría) sigue devolviendo exactamente el mismo JSON de siempre.
  defp meta_campos_detalle_extra(tabla) do
    case MetaSchemaContext.obtener_header_por_nombre(tabla) do
      nil ->
        []

      header ->
        case MetaSchemaContext.meta_campos_por_detalle(header.id) do
          m when map_size(m) == 0 -> []
          m -> [meta_campos_detalle: m]
        end
    end
  end

  # Catálogo Maestro-Detalle (R6, alta atómica): el body de un maestro
  # puede traer "renglones": {"<catalogo_detalle>": [{...}, ...]} para
  # crear el encabezado y sus renglones iniciales en la MISMA transacción
  # — se separa acá para que nunca llegue a schema_mod.changeset/2 como si
  # fuera un intento de castear un campo real (cast/2 ya lo ignoraría en
  # silencio, pero separarlo lo hace explícito). Batch (body = lista):
  # cada item puede traer su propia "renglones", ver
  # CatalogoGenerico.crear_muchos/2.
  def create(conn, %{"tabla" => tabla} = params) do
    with {:ok, schema_mod} <- resolver(tabla) do
      attrs_bruto = Map.get(params, tabla, Map.drop(params, ["tabla"]))
      estados_por_id = MetaStateEngine.mapa_nombres_estados(tabla)

      if is_list(attrs_bruto) do
        with {:ok, items} <- CatalogoGenerico.crear_muchos(schema_mod, attrs_bruto) do
          conn
          |> put_status(:created)
          |> json(%{data: Enum.map(items, &serializar_json(&1, estados_por_id))})
        end
      else
        {renglones, attrs} = Map.pop(attrs_bruto, "renglones", %{})

        with {:ok, item} <- CatalogoGenerico.crear(schema_mod, attrs, renglones: renglones) do
          conn
          |> put_status(:created)
          |> json(%{data: serializar_json(item, estados_por_id)})
        end
      end
    end
  end

  def update(conn, %{"tabla" => tabla, "id" => id} = params) do
    with {:ok, schema_mod} <- resolver(tabla) do
      attrs = Map.get(params, tabla, Map.drop(params, ["tabla", "id"]))
      item = CatalogoGenerico.obtener!(schema_mod, id)

      with {:ok, item} <- CatalogoGenerico.actualizar(item, attrs) do
        json(conn, %{data: serializar_json(item, MetaStateEngine.mapa_nombres_estados(tabla))})
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

  defp serializar_json(item, estados_por_id) do
    item
    |> CatalogoGenerico.serializar(estados_por_id)
    |> CatalogoGenerico.trn_al_final()
  end

  defp resolver(tabla) do
    case MetaSchemaContext.modulo_por_nombre(tabla) do
      nil -> {:error, :not_found}
      modulo -> {:ok, modulo}
    end
  end
end
