defmodule MetadataAppWeb.MetaTransicionController do
  @moduledoc """
  Contratos con el frontend del Motor de Estados (spec sección 7).

  - `index/2`: Contrato 1 (descubrimiento) — transiciones disponibles desde
    el estado actual del registro, con precondiciones ya evaluadas.
  - `ejecutar/2`: Contrato 2 (ejecución) — corre
    `MetadataApp.MetaStateEngine.ejecutar_transicion/3`; los desenlaces de error
    del ciclo los traduce `MetadataAppWeb.FallbackController` a los códigos
    HTTP de la tabla del spec.
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
      contexto = Map.drop(params, ["tabla", "id", "accion"])

      with {:ok, actualizado} <- MetaStateEngine.ejecutar_transicion(registro, accion, contexto) do
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

  defp serializar_transicion(t) do
    %{
      accion: t.accion,
      etiqueta: t.etiqueta,
      disponible: t.disponible,
      razones: t.razones,
      requiere: t.requiere
    }
  end

  defp resolver(tabla) do
    case MetaSchemaContext.modulo_por_nombre(tabla) do
      nil -> {:error, :not_found}
      modulo -> {:ok, modulo}
    end
  end
end
