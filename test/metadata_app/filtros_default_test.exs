defmodule MetadataApp.FiltrosDefaultTest do
  use ExUnit.Case, async: true

  alias MetadataApp.FiltrosDefault

  describe "rango_fecha/3 — modos dinámicos (\"actual\"/\"mes_actual\"/\"mes_a_fecha\"/\"anio_actual\")" do
    test "ignoran cualquier valor guardado — un valor viejo da el mismo resultado que nil" do
      valor_viejo = Date.add(Date.utc_today(), -400 * 3) |> Date.to_iso8601()

      for modo <- ["actual", "mes_actual", "mes_a_fecha", "anio_actual"] do
        assert FiltrosDefault.rango_fecha(modo, nil, nil) == FiltrosDefault.rango_fecha(modo, valor_viejo, nil)
      end
    end

    test "\"actual\" cubre el día completo de hoy (00:00:00 a 23:59:59 UTC)" do
      hoy = Date.utc_today()

      assert {desde, hasta} = FiltrosDefault.rango_fecha("actual", nil, nil)
      assert DateTime.to_date(desde) == hoy
      assert DateTime.to_date(hasta) == hoy
      assert desde.time_zone == "Etc/UTC"
    end

    test "\"mes_actual\" cubre del 1° al último día del mes EN CURSO" do
      hoy = Date.utc_today()
      assert {desde, hasta} = FiltrosDefault.rango_fecha("mes_actual", nil, nil)
      assert DateTime.to_date(desde) == Date.new!(hoy.year, hoy.month, 1)
      assert DateTime.to_date(hasta) == Date.new!(hoy.year, hoy.month, Date.days_in_month(hoy))
    end

    test "\"mes_a_fecha\" cubre del 1° del mes a HOY" do
      hoy = Date.utc_today()
      assert {desde, hasta} = FiltrosDefault.rango_fecha("mes_a_fecha", nil, nil)
      assert DateTime.to_date(desde) == Date.new!(hoy.year, hoy.month, 1)
      assert DateTime.to_date(hasta) == hoy
    end

    test "\"anio_actual\" cubre del 1/1 al 31/12 del año EN CURSO" do
      anio_actual = Date.utc_today().year
      assert {desde, hasta} = FiltrosDefault.rango_fecha("anio_actual", nil, nil)
      assert DateTime.to_date(desde) == Date.new!(anio_actual, 1, 1)
      assert DateTime.to_date(hasta) == Date.new!(anio_actual, 12, 31)
    end
  end

  describe "rango_fecha/3 — modo \"formula\" (única excepción, sí depende de texto guardado)" do
    test "parsea la fórmula de \"desde\" y \"hasta\" por separado" do
      hoy = Date.utc_today()
      assert {desde, hasta} = FiltrosDefault.rango_fecha("formula", "primer_dia_anio", "actual")
      assert DateTime.to_date(desde) == Date.new!(hoy.year, 1, 1)
      assert DateTime.to_date(hasta) == hoy
    end

    test "acepta offsets relativos, ej. \"actual - 3 meses\"" do
      esperado = MetadataApp.FormulaFecha.parsear("actual - 3 meses") |> elem(1)
      assert {desde, _hasta} = FiltrosDefault.rango_fecha("formula", "actual - 3 meses", nil)
      assert DateTime.to_date(desde) == esperado
    end

    test "\"desde\" vacío usa \"primer_dia_mes\", \"hasta\" vacío usa \"actual\"" do
      hoy = Date.utc_today()
      assert {desde, hasta} = FiltrosDefault.rango_fecha("formula", nil, nil)
      assert DateTime.to_date(desde) == Date.new!(hoy.year, hoy.month, 1)
      assert DateTime.to_date(hasta) == hoy
    end

    test "una fórmula inválida da nil (filtro apagado), no crashea" do
      assert FiltrosDefault.rango_fecha("formula", "esto no es una fórmula válida", nil) == nil
    end
  end

  describe "descripcion/3 — modos dinámicos" do
    test "describen el período actual, no un valor guardado" do
      valor_viejo = Date.add(Date.utc_today(), -400 * 3) |> Date.to_iso8601()

      for modo <- ["actual", "mes_actual", "mes_a_fecha", "anio_actual"] do
        assert FiltrosDefault.descripcion(modo, valor_viejo, nil) == FiltrosDefault.descripcion(modo, nil, nil)
      end
    end

    test "\"formula\" describe el rango resuelto, nil si no parsea" do
      assert FiltrosDefault.descripcion("formula", "primer_dia_anio", "actual") =~ "Fórmula"
      assert FiltrosDefault.descripcion("formula", "no parsea", nil) == nil
    end
  end
end
