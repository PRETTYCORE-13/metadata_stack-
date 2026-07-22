defmodule MetadataAppWeb.MetaTransicionController do
  @moduledoc """
  Contratos con el frontend del Motor de Estados (spec sección 7).

  - `index/2`: Contrato 1 (descubrimiento) — transiciones disponibles desde
    el estado actual del registro, con precondiciones ya evaluadas.
  - `ejecutar/2`: Contrato 2 (ejecución) — corre
    `MetadataApp.MetaStateEngine.ejecutar_transicion/4`; los desenlaces de error
    del ciclo los traduce `MetadataAppWeb.FallbackController` a los códigos
    HTTP de la tabla del spec. Catálogo Maestro-Detalle (Fase 2): el body
    puede traer `"renglones": {"<catalogo_detalle>": [renglon_id, ...]}`
    para mover renglones junto con el encabezado en la misma transición —
    esa llave se saca de `contexto` antes de pasarlo, nunca llega como un
    intento de editar un campo del header.
  """

  use MetadataAppWeb, :controller
  alias MetadataApp.BusinessProcessBuilder.{CatalogoGenerico, MetaSchemaContext}
  alias MetadataApp.MetaStateEngine

  action_fallback MetadataAppWeb.FallbackController

  def index(conn, %{"tabla" => tabla, "id" => id} = params) do
    with {:ok, schema_mod} <- resolver(tabla) do
      registro = CatalogoGenerico.obtener!(schema_mod, id)
      contexto = Map.get(params, "contexto", %{})

      data =
        registro
        |> MetaStateEngine.transiciones_disponibles(contexto)
        |> Enum.map(&serializar_transicion/1)

      json(conn, %{data: data})
    end
  end

  def ejecutar(conn, %{"tabla" => tabla, "id" => id, "accion" => accion} = params) do
    with {:ok, schema_mod} <- resolver(tabla) do
      registro = CatalogoGenerico.obtener!(schema_mod, id)
      renglones = Map.get(params, "renglones", %{})
      contexto = Map.drop(params, ["tabla", "id", "accion", "renglones"])

      with {:ok, actualizado} <- MetaStateEngine.ejecutar_transicion(registro, accion, contexto, renglones: renglones) do
        # Descubrimiento incluido desde el nuevo estado, para que el
        # frontend repinte los botones disponibles en un solo viaje.
        transiciones =
          actualizado
          |> MetaStateEngine.transiciones_disponibles(contexto)
          |> Enum.map(&serializar_transicion/1)

        estados_por_id = MetaStateEngine.mapa_nombres_estados(tabla)
      json(conn, %{data: CatalogoGenerico.serializar(actualizado, estados_por_id), transiciones: transiciones})
      end
    end
  end

  # Sin :requiere (retirado junto con requiere_de/1 en el rediseño de
  # reglas 2026-07-21 — MetaStateEngine.transiciones_disponibles/2 ya no
  # lo genera). Bug real: este map literal seguía leyéndolo y crasheaba
  # (KeyError) cada vez que alguien pegaba GET /:tabla/:id/transiciones.
  defp serializar_transicion(t) do
    %{
      accion: t.accion,
      etiqueta: t.etiqueta,
      disponible: t.disponible,
      razones: t.razones
    }
  end

  defp resolver(tabla) do
    case MetaSchemaContext.modulo_por_nombre(tabla) do
      nil -> {:error, :not_found}
      modulo -> {:ok, modulo}
    end
  end
end
