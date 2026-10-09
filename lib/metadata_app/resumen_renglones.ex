defmodule MetadataApp.ResumenRenglones do
  @moduledoc """
  Cálculo de la fila de resumen (pie fijo) de la tabla de renglones (ver
  `MetadataAppWeb.GridEditableComponents`, tab "Detalle" de la Ficha
  360°) — misma regla que `GridEditableComponents.resumen_estandar/2`:
  cada columna numérica usa la operación de su campo ("Total en
  renglones": suma por default, promedio, o ninguno y no participa); el
  resto no participa. Misma semántica de operación que `calcularResumen` en
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

    operacion = MetadataApp.BusinessProcessBuilder.MetaSchemaContext.total_renglones(props)

    if props["tipo"] in @tipos_numericos and operacion != "ninguno" do
      numeros = renglones |> valores_columna(col.schema_context_field) |> numeros()
      valor = operar(operacion, numeros)

      %{
        campo: col.schema_context_field,
        operacion: operacion,
        etiqueta: if(operacion == "promedio", do: "Prom.", else: "Total"),
        valor: valor,
        texto: formatear(valor)
      }
    end
  end

  defp operar("promedio", []), do: 0.0
  defp operar("promedio", numeros), do: Enum.sum(numeros) / length(numeros)
  defp operar(_suma, numeros), do: Enum.sum(numeros)

  defp valores_columna(renglones, campo) do
    renglones
    |> Enum.map(&Map.get(&1, campo))
    |> Enum.reject(&vacio?/1)
  end

  defp vacio?(nil), do: true
  defp vacio?(""), do: true
  defp vacio?(_), do: false

  defp numeros(valores) do
    valores
    |> Enum.map(&to_numero/1)
    |> Enum.reject(&is_nil/1)
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
