defmodule MetadataApp.FiltrosDefault do
  @moduledoc """
  Toda la lógica de "Filtros por default" (Header.filtro_default_fecha_modo/
  filtro_default_fecha_valor/filtro_default_fecha_valor_hasta, y el
  "parametro" => "fecha" de MetaSchema.Consulta.campos) — separado de
  `BcMotorLive`/`FiltrosDefaultComponents` (que solo dibujan) para que
  cualquier otra pantalla de "filtro por default" reuse este módulo en vez
  de duplicar los `case modo do`.
  """

  alias MetadataApp.FormulaFecha

  @doc "Los modos del botonera del filtro genérico del BC (Header.filtro_default_fecha_modo), en el orden que se muestran."
  def modos_fecha do
    [
      {"", "Sin acotar"},
      {"actual", "Fecha actual"},
      {"mes_actual", "Mes actual completo"},
      {"mes_a_fecha", "Mes actual a la fecha"},
      {"anio_actual", "Año actual completo"},
      {"formula", "Fórmula"}
    ]
  end

  @doc "Defaults de un campo Fecha ACOTADO (Consulta.campos, ver moduledoc de MetaSchema.Consulta) -- siempre un rango de dos extremos."
  def modos_fecha_rango do
    [
      {"mes_actual", "Mes actual completo"},
      {"mes_a_fecha", "Mes actual a la fecha"},
      {"anio_actual", "Año actual completo"},
      {"formula", "Fórmula"}
    ]
  end

  @doc "Defaults de un campo Fecha SIN acotar (Consulta.campos) -- un solo valor, sin rango."
  def modos_fecha_simple do
    [
      {"actual", "Fecha actual"},
      {"primer_dia_mes", "Inicio de mes"},
      {"primer_dia_anio", "Inicio de año"},
      {"formula", "Fórmula"}
    ]
  end

  @doc """
  Traduce modo + `valor`/`valor_hasta` a un {desde, hasta} en UTC — filtro
  directo contra una columna de fecha real.

  Todos los modos salvo "formula" son dinámicos: ignoran `valor`/
  `valor_hasta` y calculan siempre contra `Date.utc_today()` del momento
  en que se llama — un filtro configurado hoy sigue siendo correcto
  mañana, el año que viene, siempre, sin que nadie tenga que volver a
  tocarlo.

  "formula" es el único que depende de texto guardado: `valor` es la
  fórmula de "desde" (ver `MetadataApp.FormulaFecha`, default
  "primer_dia_mes" si viene vacío) y `valor_hasta` la de "hasta" (default
  "actual" si viene vacío) — a propósito NUNCA fechas ya resueltas, así
  que un filtro guardado como "actual - 3 meses" sigue moviéndose con el
  calendario en vez de quedar pegado al día en que se configuró.

  nil si el modo no matchea ninguno (filtro apagado) o si alguna fórmula
  de "formula" no parsea.
  """
  def rango_fecha(modo, valor, valor_hasta \\ nil)

  def rango_fecha("actual", _valor, _valor_hasta) do
    hoy = Date.utc_today()
    {inicio_dia(hoy), fin_dia(hoy)}
  end

  def rango_fecha("mes_actual", _valor, _valor_hasta) do
    hoy = Date.utc_today()
    desde = Date.new!(hoy.year, hoy.month, 1)
    hasta = Date.new!(hoy.year, hoy.month, Date.days_in_month(hoy))
    {inicio_dia(desde), fin_dia(hasta)}
  end

  def rango_fecha("mes_a_fecha", _valor, _valor_hasta) do
    hoy = Date.utc_today()
    desde = Date.new!(hoy.year, hoy.month, 1)
    {inicio_dia(desde), fin_dia(hoy)}
  end

  def rango_fecha("anio_actual", _valor, _valor_hasta) do
    hoy = Date.utc_today()
    {inicio_dia(Date.new!(hoy.year, 1, 1)), fin_dia(Date.new!(hoy.year, 12, 31))}
  end

  def rango_fecha("primer_dia_mes", _valor, _valor_hasta) do
    hoy = Date.utc_today()
    dia = Date.new!(hoy.year, hoy.month, 1)
    {inicio_dia(dia), fin_dia(dia)}
  end

  def rango_fecha("primer_dia_anio", _valor, _valor_hasta) do
    dia = Date.new!(Date.utc_today().year, 1, 1)
    {inicio_dia(dia), fin_dia(dia)}
  end

  def rango_fecha("formula", valor, valor_hasta) do
    desde_formula = texto_o_default(valor, "primer_dia_mes")
    hasta_formula = texto_o_default(valor_hasta, "actual")

    with {:ok, desde} <- FormulaFecha.parsear(desde_formula),
         {:ok, hasta} <- FormulaFecha.parsear(hasta_formula) do
      {inicio_dia(desde), fin_dia(hasta)}
    else
      _ -> nil
    end
  end

  def rango_fecha(_modo, _valor, _valor_hasta), do: nil

  defp texto_o_default(texto, _default) when is_binary(texto) and texto != "", do: texto
  defp texto_o_default(_texto, default), do: default

  defp inicio_dia(%Date{} = data), do: DateTime.new!(data, ~T[00:00:00], "Etc/UTC")
  defp fin_dia(%Date{} = data), do: DateTime.new!(data, ~T[23:59:59], "Etc/UTC")

  @doc """
  Texto legible del filtro activo, para mostrarle al usuario FINAL en la
  tabla del catálogo (CatalogoLive) — no solo al que lo configura — así
  entiende por qué está viendo menos registros de los que hay en total.
  nil si el filtro está apagado o si "formula" tiene alguna fórmula que no
  parsea.
  """
  def descripcion(modo, valor, valor_hasta \\ nil)

  def descripcion("actual", _valor, _valor_hasta) do
    "Fecha actual — hoy (#{formatear(Date.utc_today())})"
  end

  def descripcion("mes_actual", _valor, _valor_hasta) do
    hoy = Date.utc_today()
    desde = Date.new!(hoy.year, hoy.month, 1)
    hasta = Date.new!(hoy.year, hoy.month, Date.days_in_month(hoy))
    "Mes actual completo — del #{formatear(desde)} al #{formatear(hasta)}"
  end

  def descripcion("mes_a_fecha", _valor, _valor_hasta) do
    hoy = Date.utc_today()
    desde = Date.new!(hoy.year, hoy.month, 1)
    "Mes actual a la fecha — del #{formatear(desde)} al #{formatear(hoy)}"
  end

  def descripcion("anio_actual", _valor, _valor_hasta) do
    hoy = Date.utc_today()
    "Año actual completo — del 1/1/#{hoy.year} al 31/12/#{hoy.year}"
  end

  def descripcion("primer_dia_mes", _valor, _valor_hasta) do
    hoy = Date.utc_today()
    "Inicio de mes — #{formatear(Date.new!(hoy.year, hoy.month, 1))}"
  end

  def descripcion("primer_dia_anio", _valor, _valor_hasta) do
    "Inicio de año — 1/1/#{Date.utc_today().year}"
  end

  def descripcion("formula", valor, valor_hasta) do
    desde_formula = texto_o_default(valor, "primer_dia_mes")
    hasta_formula = texto_o_default(valor_hasta, "actual")

    with {:ok, desde} <- FormulaFecha.parsear(desde_formula),
         {:ok, hasta} <- FormulaFecha.parsear(hasta_formula) do
      "Fórmula — del #{formatear(desde)} al #{formatear(hasta)}"
    else
      _ -> nil
    end
  end

  def descripcion(_modo, _valor, _valor_hasta), do: nil

  defp formatear(%Date{} = data) do
    data |> Calendar.strftime("%d/%m/%Y")
  end
end
