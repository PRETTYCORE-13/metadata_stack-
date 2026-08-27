defmodule MetadataApp.FormulaFecha do
  @moduledoc """
  DSL segura para fechas relativas ("fórmulas") — usada por
  `MetadataApp.FiltrosDefault.rango_fecha/3` en el modo "formula". A
  propósito NUNCA ejecuta código (nada de `Code.eval_string`): un texto
  libre tipo "Fecha actual - 3 meses" sería una superficie de ejecución de
  código arbitrario en el servidor si se evaluara como Elixir real. Acá se
  parsea contra una gramática fija y se resuelve con aritmética de
  `Date`, así que cualquier texto que no matchee da un error de
  validación en vez de fallar silencioso o (peor) correr algo.

  Gramática: `<base> [<+|-> <N> <unidad>]*`

    * `base` — "actual" (hoy), "primer_dia_mes", "primer_dia_anio", o una
      fecha literal ISO ("2026-01-01").
    * `unidad` — dia/dias, mes/meses, anio/anios/año/años.

  Ejemplos válidos: "actual", "actual - 3 meses", "primer_dia_mes - 1 mes",
  "primer_dia_anio + 6 meses", "2026-01-01 + 15 dias".
  """

  @bases ~w(actual primer_dia_mes primer_dia_anio)
  @unidades ~w(dia dias mes meses anio anios año años)

  @doc """
  Parsea `texto` contra `hoy` (default `Date.utc_today/0`, inyectable para
  tests deterministas) y devuelve `{:ok, Date.t()}` o `{:error, mensaje}`.
  """
  def parsear(texto, hoy \\ Date.utc_today())

  def parsear(nil, _hoy), do: {:error, "Fórmula vacía"}

  def parsear(texto, hoy) when is_binary(texto) do
    case String.trim(texto) do
      "" -> {:error, "Fórmula vacía"}
      texto -> parsear_tokens(String.split(texto), hoy)
    end
  end

  defp parsear_tokens([base_token | resto], hoy) do
    with {:ok, base} <- resolver_base(base_token, hoy),
         {:ok, offsets} <- parsear_offsets(resto) do
      {:ok, aplicar_offsets(base, offsets)}
    end
  end

  defp resolver_base("actual", hoy), do: {:ok, hoy}
  defp resolver_base("primer_dia_mes", hoy), do: {:ok, Date.new!(hoy.year, hoy.month, 1)}
  defp resolver_base("primer_dia_anio", hoy), do: {:ok, Date.new!(hoy.year, 1, 1)}

  defp resolver_base(texto, _hoy) do
    case Date.from_iso8601(texto) do
      {:ok, data} ->
        {:ok, data}

      _ ->
        {:error,
         "Base inválida: \"#{texto}\" (usa #{Enum.join(@bases, ", ")} o una fecha AAAA-MM-DD)"}
    end
  end

  defp parsear_offsets([]), do: {:ok, []}

  defp parsear_offsets([signo, cantidad_texto, unidad | resto]) when signo in ["+", "-"] do
    with {n, ""} when n > 0 <- Integer.parse(cantidad_texto),
         true <- unidad in @unidades,
         {:ok, resto_offsets} <- parsear_offsets(resto) do
      n = if signo == "-", do: -n, else: n
      {:ok, [{n, normalizar_unidad(unidad)} | resto_offsets]}
    else
      _ ->
        {:error,
         "No se entiende \"#{signo} #{cantidad_texto} #{unidad}\" (formato: + N dias/meses/anios)"}
    end
  end

  defp parsear_offsets(tokens) do
    {:error,
     "No se pudo interpretar \"#{Enum.join(tokens, " ")}\" (formato: + N dias/meses/anios)"}
  end

  defp normalizar_unidad(u) when u in ~w(dia dias), do: :dias
  defp normalizar_unidad(u) when u in ~w(mes meses), do: :meses
  defp normalizar_unidad(u) when u in ~w(anio anios año años), do: :anios

  defp aplicar_offsets(data, offsets), do: Enum.reduce(offsets, data, &aplicar_offset/2)

  defp aplicar_offset({n, :dias}, data), do: Date.add(data, n)
  defp aplicar_offset({n, :meses}, data), do: sumar_meses(data, n)
  defp aplicar_offset({n, :anios}, data), do: sumar_meses(data, n * 12)

  # Clamp de fin de mes: 31 ene - 1 mes -> 31 dic (mes anterior tiene 31,
  # ok); 31 mar - 1 mes -> 28/29 feb (no 31, clampea al último día real
  # del mes destino en vez de reventar con Date.new!/3).
  defp sumar_meses(%Date{year: year, month: month, day: day}, n) do
    total_meses = year * 12 + (month - 1) + n
    nuevo_year = Integer.floor_div(total_meses, 12)
    nuevo_month = Integer.mod(total_meses, 12) + 1
    ultimo_dia_mes_destino = Date.new!(nuevo_year, nuevo_month, 1) |> Date.days_in_month()
    Date.new!(nuevo_year, nuevo_month, min(day, ultimo_dia_mes_destino))
  end
end
