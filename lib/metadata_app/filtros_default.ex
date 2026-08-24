defmodule MetadataApp.FiltrosDefault do
  @moduledoc """
  Toda la lógica de "Filtros por default" (Header.filtro_default_fecha_modo/
  filtro_default_fecha_valor/filtro_default_fecha_valor_hasta) — separado
  de `BcMotorLive`/`FiltrosDefaultComponents` (que solo dibujan) para que
  cualquier otra pantalla que sume su propio tipo de "filtro por default"
  más adelante reuse este módulo en vez de duplicar los `case modo do`.

  Hoy solo hay un tipo (fecha de alta), pero está separado a propósito para
  no atar el nombre del módulo a "fecha" — un filtro por default futuro
  (ej. por otro campo) puede sumar sus propias funciones acá.
  """

  @doc "Los 5 modos del botonera, en el orden que se muestran."
  def modos_fecha do
    [
      {"", "Sin acotar"},
      {"primer_dia_anio", "Primer día del año"},
      {"ultimo_dia_anio", "Último día del año"},
      {"actual", "Fecha actual"},
      {"rango", "Fecha inicial y final"}
    ]
  end

  @doc """
  Traduce modo ("primer_dia_anio"/"ultimo_dia_anio"/"actual"/"rango") +
  valor/valor_hasta (Date, solo relevantes para "rango") a un {desde, hasta}
  en UTC — filtro directo contra la columna real "fecha_registro" (ver
  CatalogoLive.filtros_por_default/1).

  "actual", "primer_dia_anio" y "ultimo_dia_anio" son dinámicos: ignoran
  `valor`/`valor_hasta` a propósito y calculan siempre contra
  `Date.utc_today()` del momento en que se llama — un filtro configurado
  hoy sigue siendo correcto mañana, el año que viene, siempre, sin que
  nadie tenga que volver a tocarlo. Solo "rango" depende de una fecha
  guardada (dos, de hecho) — por diseño: un rango es un par de fechas
  puntuales elegidas a propósito, no un período relativo a "hoy".

  nil si el modo no matchea ninguno de los cuatro (filtro de fecha
  apagado) o si "rango" todavía no tiene las dos fechas que necesita.
  """
  def rango_fecha(modo, valor, valor_hasta \\ nil)

  def rango_fecha("actual", _valor, _valor_hasta) do
    hoy = Date.utc_today()
    {DateTime.new!(hoy, ~T[00:00:00], "Etc/UTC"), DateTime.new!(hoy, ~T[23:59:59], "Etc/UTC")}
  end

  def rango_fecha("primer_dia_anio", _valor, _valor_hasta) do
    desde = Date.new!(Date.utc_today().year, 1, 1)
    {DateTime.new!(desde, ~T[00:00:00], "Etc/UTC"), DateTime.new!(~D[9999-12-31], ~T[23:59:59], "Etc/UTC")}
  end

  def rango_fecha("ultimo_dia_anio", _valor, _valor_hasta) do
    hasta = Date.new!(Date.utc_today().year, 12, 31)
    {DateTime.new!(~D[1900-01-01], ~T[00:00:00], "Etc/UTC"), DateTime.new!(hasta, ~T[23:59:59], "Etc/UTC")}
  end

  def rango_fecha("rango", %Date{} = desde, %Date{} = hasta) do
    {DateTime.new!(desde, ~T[00:00:00], "Etc/UTC"), DateTime.new!(hasta, ~T[23:59:59], "Etc/UTC")}
  end

  def rango_fecha(_modo, _valor, _valor_hasta), do: nil

  @doc """
  Texto legible del filtro activo, para mostrarle al usuario FINAL en la
  tabla del catálogo (CatalogoLive) — no solo al que lo configura en
  BcMotorLive — así entiende por qué está viendo menos registros de los
  que hay en total. nil si el filtro está apagado o si el modo necesita
  una fecha que todavía no se eligió (ej. "rango" con un solo extremo).
  """
  def descripcion(modo, valor, valor_hasta \\ nil)

  def descripcion("actual", _valor, _valor_hasta) do
    "Fecha actual — hoy (#{formatear(Date.utc_today())})"
  end

  def descripcion("primer_dia_anio", _valor, _valor_hasta) do
    "Primer día del año — desde 1/1/#{Date.utc_today().year}"
  end

  def descripcion("ultimo_dia_anio", _valor, _valor_hasta) do
    "Último día del año — hasta 31/12/#{Date.utc_today().year}"
  end

  def descripcion("rango", %Date{} = desde, %Date{} = hasta) do
    "Fecha inicial y final — del #{formatear(desde)} al #{formatear(hasta)}"
  end

  def descripcion(_modo, _valor, _valor_hasta), do: nil

  defp formatear(%Date{} = data) do
    data |> Calendar.strftime("%d/%m/%Y")
  end
end
