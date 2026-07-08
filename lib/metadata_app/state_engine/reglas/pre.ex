defmodule MetadataApp.StateEngine.Reglas.Pre do
  @moduledoc """
  Precondiciones del vocabulario del Motor de Estados (spec sección 5).
  Contrato: (registro, contexto, params) -> :ok | {:error, mensaje}. Solo
  lectura, nunca mutan nada.

  `sin_relacionados` opera sobre catálogos genéricos que no necesariamente
  tienen un módulo Ecto propio conocido de antemano, así que usa queries
  schemaless (`from t in "nombre_tabla"`), igual que ya hace
  `CatalogoGenerador.impacto/1` en el resto del proyecto.
  """

  import Ecto.Query
  alias MetadataApp.Repo

  # campos_requeridos: {campos: [lista]} — todos no vacíos en el registro.
  def evaluar("campos_requeridos", registro, _contexto, %{"campos" => campos}) do
    faltantes = Enum.filter(campos, &vacio?(Map.get(registro, String.to_existing_atom(&1))))

    case faltantes do
      [] -> :ok
      _ -> {:error, "faltan completar: #{Enum.join(faltantes, ", ")}"}
    end
  end

  # campo_cumple: {campo, operador, valor} — ej. limite_credito > 0.
  def evaluar("campo_cumple", registro, _contexto, %{
        "campo" => campo,
        "operador" => operador,
        "valor" => esperado
      }) do
    actual = Map.get(registro, String.to_existing_atom(campo))

    if comparar(actual, operador, esperado) do
      :ok
    else
      {:error,
       "#{campo} no cumple: se esperaba #{campo} #{operador} #{inspect(esperado)}, es #{inspect(actual)}"}
    end
  end

  # sin_relacionados: {entidad, campo_relacion, filtro?} — ej. sin pedidos
  # abiertos para dar de baja. `campo_relacion` es la columna en `entidad` que
  # apunta de vuelta al registro actual (la FK); `filtro` (opcional) es
  # {campo, valor} adicional, ej. limitar a solo los "abiertos".
  def evaluar("sin_relacionados", registro, _contexto, params) do
    entidad = Map.fetch!(params, "entidad")
    campo_relacion = Map.fetch!(params, "campo_relacion")
    # to_existing_atom/1 exige que el átomo ya exista en la VM -- si el
    # módulo Ecto de `entidad` nunca se cargó en este proceso (ej. un mix
    # run que nunca lo tocó antes), el átomo del campo todavía no existe
    # aunque la tabla sí. Cargar el módulo primero lo registra.
    MetadataApp.MetaSchemaContext.modulo_por_nombre(entidad)

    query =
      from(t in entidad,
        where: field(t, ^String.to_existing_atom(campo_relacion)) == ^registro.id
      )
      |> aplicar_filtro(Map.get(params, "filtro"))

    case Repo.aggregate(query, :count) do
      0 -> :ok
      n -> {:error, "tiene #{n} registro(s) relacionado(s) en #{entidad}"}
    end
  end

  # requiere_rol: {rol} — delega en MetadataApp.Permissions.can?/3.
  def evaluar("requiere_rol", _registro, contexto, %{"rol" => rol}) do
    if MetadataApp.Permissions.can?(contexto, rol) do
      :ok
    else
      {:error, "requiere el rol: #{rol}"}
    end
  end

  # dato_en_contexto: {dato} — ej. motivo_baja capturado por el frontend.
  def evaluar("dato_en_contexto", _registro, contexto, %{"dato" => dato}) do
    case Map.get(contexto, dato) do
      nil -> {:error, "falta el dato: #{dato}"}
      "" -> {:error, "falta el dato: #{dato}"}
      _ -> :ok
    end
  end

  defp aplicar_filtro(query, nil), do: query

  defp aplicar_filtro(query, %{"campo" => campo, "valor" => valor}) do
    from t in query, where: field(t, ^String.to_existing_atom(campo)) == ^valor
  end

  defp vacio?(nil), do: true
  defp vacio?(""), do: true
  defp vacio?(_valor), do: false

  defp comparar(%Decimal{} = actual, operador, esperado) do
    esperado_decimal =
      if match?(%Decimal{}, esperado), do: esperado, else: Decimal.new(to_string(esperado))

    comparacion = Decimal.compare(actual, esperado_decimal)

    case {operador, comparacion} do
      {">", :gt} -> true
      {">=", c} -> c in [:gt, :eq]
      {"<", :lt} -> true
      {"<=", c} -> c in [:lt, :eq]
      {"==", :eq} -> true
      {"!=", c} -> c in [:gt, :lt]
      _ -> false
    end
  end

  defp comparar(actual, ">", esperado), do: actual > esperado
  defp comparar(actual, ">=", esperado), do: actual >= esperado
  defp comparar(actual, "<", esperado), do: actual < esperado
  defp comparar(actual, "<=", esperado), do: actual <= esperado
  defp comparar(actual, "==", esperado), do: actual == esperado
  defp comparar(actual, "!=", esperado), do: actual != esperado
end
