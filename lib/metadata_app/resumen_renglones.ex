defmodule MetadataApp.ResumenRenglones do
  @moduledoc """
  Cálculo de la fila de resumen (pie fijo) de la grilla de renglones (ver
  `MetadataAppWeb.GridEditableComponents`, tab "Detalle" de la Ficha
  360°) — estándar fijo para TODAS las grillas de renglones, sin
  configuración por catálogo (ver `GridEditableComponents.resumen_estandar/1`,
  misma regla replicada acá): toda columna numérica suma, el resto no
  participa. Misma semántica de operación que `calcularResumen` en
  `assets/js/hooks/grid_editable.js` (nombres de operación mapeables 1:1),
  pero de servidor: trabaja sobre una lista de mapas ya en memoria, no una
  query Ecto (a diferencia de `CatalogoGenerico.agregar/5`, usado por Get
  View, que sí filtra en la base) — así también sirve para renglones
  nuevos/editados de la sesión actual que todavía no están persistidos.
  """

  @tipos_numericos ["integer", "decimal"]

  @doc """
  `renglones` es una lista de mapas `%{"campo" => valor}` (o structs Ecto,
  cualquier cosa que responda a `Map.get/2`); `columnas` es una lista de
  detalles serializados (`MetaSchemaContext.serializar_detalle/1` o
  equivalente, con `.schema_context_field`/`.schema_context_properties`).
  Devuelve un mapa `%{campo => %{operacion:, etiqueta:, valor:, texto:}}`
  con SOLO las columnas numéricas.
  """
  def calcular(renglones, columnas) do
    columnas
    |> Enum.map(&resumen_columna(&1, renglones))
    |> Enum.reject(&is_nil/1)
    |> Map.new(&{&1.campo, &1})
  end

  defp resumen_columna(col, renglones) do
    props = col.schema_context_properties || %{}

    if props["tipo"] in @tipos_numericos do
      valores = valores_columna(renglones, col.schema_context_field)
      valor = sumar(valores)

      %{
        campo: col.schema_context_field,
        operacion: "suma",
        etiqueta: "Total",
        valor: valor,
        texto: formatear(valor)
      }
    end
  end

  defp valores_columna(renglones, campo) do
    renglones
    |> Enum.map(&Map.get(&1, campo))
    |> Enum.reject(&vacio?/1)
  end

  defp vacio?(nil), do: true
  defp vacio?(""), do: true
  defp vacio?(_), do: false

  defp sumar(valores) do
    valores
    |> Enum.map(&to_numero/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  defp to_numero(valor) when is_number(valor), do: valor
  defp to_numero(%Decimal{} = valor), do: Decimal.to_float(valor)

  defp to_numero(valor) when is_binary(valor) do
    case Float.parse(valor) do
      {numero, _resto} -> numero
      :error -> nil
    end
  end

  defp to_numero(_valor), do: nil

  defp formatear(valor), do: :erlang.float_to_binary(valor / 1, decimals: 2)
end
