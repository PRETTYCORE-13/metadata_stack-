defmodule MetadataAppWeb.BusinessProcessBuilder.ConsultaController do
  # GET /api/<consulta> -- reporte de solo lectura (Consulta Ecto,
  # schema_context_type: 3). Reusa MetaConsultas (mismo motor que
  # CatalogoLive) en vez de duplicar el armado de la query. Se llama
  # directo desde CatalogoController.index/2 cuando el header resuelve a
  # una Consulta -- mismo path "/api/:tabla" que un catálogo normal, no
  # hace falta una ruta nueva en el router. Sin show/create/update/delete
  # a propósito: una Consulta nunca transacciona.
  use MetadataAppWeb, :controller

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaConsultas

  @por_pagina_default 25
  @por_pagina_maximo 100

  def index(conn, %{"tabla" => nombre} = params) do
    header = MetaSchemaContext.obtener_header_por_nombre(nombre)
    consulta = MetaConsultas.obtener_por_header_id(header.id)

    {pagina, por_pagina} = resolver_paginacion(params)
    offset = (pagina - 1) * por_pagina
    filtros = filtros_desde_params(consulta, params)

    resultado =
      MetaConsultas.ejecutar(consulta, conn.assigns[:current_scope], filtros, [limit: por_pagina, offset: offset])

    json(
      conn,
      Jason.OrderedObject.new(
        meta_campos: meta_campos(consulta),
        data: Enum.map(resultado.filas, &serializar_mapa/1),
        totales: serializar_mapa(resultado.totales),
        paginacion: %{
          pagina: pagina,
          por_pagina: por_pagina,
          total_filas: resultado.total_filas,
          total_paginas: total_paginas(resultado.total_filas, por_pagina)
        }
      )
    )
  end

  # Solo las columnas visibles (Get Config), en el mismo orden que la
  # tabla admin/report -- "clave" es la llave namespaced que también
  # trae cada fila de "data" (MetaConsultas.clave_campo/1), necesaria
  # para leer el JSON sin ambigüedad cuando dos tablas unidas comparten
  # nombre de campo (ej. dos "fecha_registro").
  defp meta_campos(consulta) do
    consulta.campos
    |> Enum.filter(&(&1["visible"] == true))
    |> Enum.sort_by(&Map.get(&1, "orden", 0))
    |> Enum.map(fn campo ->
      %{
        clave: campo |> MetaConsultas.clave_campo() |> to_string(),
        catalogo: campo["catalogo"],
        campo: campo["campo"],
        etiqueta: campo["etiqueta"],
        tipo: campo["tipo"]
      }
    end)
  end

  defp serializar_mapa(mapa), do: Map.new(mapa, fn {clave, valor} -> {to_string(clave), valor} end)

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

  # Solo igualdad exacta por query string, mismo criterio que
  # CatalogoController.filtros_desde_params/2 -- "campo" es siempre el
  # nombre crudo (sin catálogo), coherente con cómo
  # MetaConsultas.ejecutar/5 resuelve filtros (primer campo que matchea
  # por nombre -- ambiguo si dos tablas unidas comparten nombre, misma
  # limitación ya aceptada en la UI admin).
  defp filtros_desde_params(consulta, params) do
    tipos = Map.new(consulta.campos, &{&1["campo"], tipo_para_filtro(&1)})

    params
    |> Map.drop(["tabla", "pagina", "por_pagina"])
    |> Enum.reduce(%{}, fn {campo, valor}, acc ->
      case Map.fetch(tipos, campo) do
        {:ok, tipo} -> Map.put(acc, campo, convertir_filtro(valor, tipo))
        :error -> acc
      end
    end)
  end

  # Campo de control -- "tipo" viene nil en @campos (ver Consulta.campos):
  # todos son id numérico salvo "trn".
  defp tipo_para_filtro(%{"control" => true, "campo" => "trn"}), do: "string"
  defp tipo_para_filtro(%{"control" => true}), do: "integer"
  defp tipo_para_filtro(%{"tipo" => tipo}), do: tipo || "string"

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
end
