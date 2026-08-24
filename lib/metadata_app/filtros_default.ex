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
  valor/valor_hasta (Date, elegidos por calendario) a un {desde, hasta} en
  UTC — filtro directo contra la columna real "fecha_registro" (ver
  CatalogoLive.filtros_por_default/1). "actual" ignora `valor` a propósito
  y usa SIEMPRE `Date.utc_today()` del momento en que se llama — es un
  filtro dinámico ("hoy" de verdad, se corre solo cada día), no una fecha
  fija elegida una vez (a diferencia de los otros 3 modos, que sí dependen
  de una fecha guardada). "primer_dia_anio" y "ultimo_dia_anio" usan el AÑO
  de `valor` para calcular el 1/1 o 31/12 correspondiente. nil si el modo
  no matchea ninguno de los cuatro (filtro de fecha apagado) o si todavía
  falta alguna fecha que ese modo necesita.
  """
  def rango_fecha(modo, valor, valor_hasta \\ nil)

  def rango_fecha("actual", _valor, _valor_hasta) do
    hoy = Date.utc_today()
    {DateTime.new!(hoy, ~T[00:00:00], "Etc/UTC"), DateTime.new!(hoy, ~T[23:59:59], "Etc/UTC")}
  end

  def rango_fecha("primer_dia_anio", %Date{} = valor, _valor_hasta) do
    desde = Date.new!(valor.year, 1, 1)
    {DateTime.new!(desde, ~T[00:00:00], "Etc/UTC"), DateTime.new!(~D[9999-12-31], ~T[23:59:59], "Etc/UTC")}
  end

  def rango_fecha("ultimo_dia_anio", %Date{} = valor, _valor_hasta) do
    hasta = Date.new!(valor.year, 12, 31)
    {DateTime.new!(~D[1900-01-01], ~T[00:00:00], "Etc/UTC"), DateTime.new!(hasta, ~T[23:59:59], "Etc/UTC")}
  end

  def rango_fecha("rango", %Date{} = desde, %Date{} = hasta) do
    {DateTime.new!(desde, ~T[00:00:00], "Etc/UTC"), DateTime.new!(hasta, ~T[23:59:59], "Etc/UTC")}
  end

  def rango_fecha(_modo, _valor, _valor_hasta), do: nil

  @doc """
  Valor con el que se precarga el calendario apenas se elige un modo de una
  sola fecha ("primer_dia_anio"/"ultimo_dia_anio") — el usuario lo puede
  cambiar después. "actual" no tiene calendario (es dinámico, ver
  rango_fecha/3) y "rango" no tiene un valor obvio para ninguno de sus dos
  extremos, así que ninguno de los dos precarga nada (nil).
  """
  def valor_default_para_modo(modo) do
    hoy = Date.utc_today()

    case modo do
      "primer_dia_anio" -> Date.new!(hoy.year, 1, 1)
      "ultimo_dia_anio" -> Date.new!(hoy.year, 12, 31)
      _ -> nil
    end
  end

  @doc "Etiqueta arriba del calendario único (\"primer_dia_anio\"/\"ultimo_dia_anio\" — \"actual\" no tiene calendario, ver moduledoc de rango_fecha/3)."
  def etiqueta_calendario_unico(_modo), do: "Elegí cualquier día de este año"

  @doc """
  min/max del `<input type="date">` — "primer_dia_anio"/"ultimo_dia_anio"
  acotan siempre al año EN CURSO (no cualquier año que el usuario tipee a
  mano), el calendario solo deja elegir el día dentro de ese año.
  """
  def min_calendario_unico(modo) when modo in ["primer_dia_anio", "ultimo_dia_anio"] do
    Date.new!(Date.utc_today().year, 1, 1)
  end

  def min_calendario_unico(_modo), do: nil

  def max_calendario_unico(modo) when modo in ["primer_dia_anio", "ultimo_dia_anio"] do
    Date.new!(Date.utc_today().year, 12, 31)
  end

  def max_calendario_unico(_modo), do: nil

  @doc """
  Re-validación server-side de que `valor` (string ISO8601 crudo del
  formulario) sea del año en curso para "primer_dia_anio"/"ultimo_dia_anio"
  — el min/max del `<input type="date">` es solo del lado del cliente, se
  puede saltear escribiendo el valor a mano.
  """
  def fecha_fuera_de_anio_actual?(modo, valor) when modo in ["primer_dia_anio", "ultimo_dia_anio"] do
    case Date.from_iso8601(valor) do
      {:ok, %Date{year: year}} -> year != Date.utc_today().year
      _ -> false
    end
  end

  def fecha_fuera_de_anio_actual?(_modo, _valor), do: false

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

  def descripcion("primer_dia_anio", %Date{} = valor, _valor_hasta) do
    "Primer día del año — desde 1/1/#{valor.year}"
  end

  def descripcion("ultimo_dia_anio", %Date{} = valor, _valor_hasta) do
    "Último día del año — hasta 31/12/#{valor.year}"
  end

  def descripcion("rango", %Date{} = desde, %Date{} = hasta) do
    "Fecha inicial y final — del #{formatear(desde)} al #{formatear(hasta)}"
  end

  def descripcion(_modo, _valor, _valor_hasta), do: nil

  defp formatear(%Date{} = data) do
    data |> Calendar.strftime("%d/%m/%Y")
  end
end
