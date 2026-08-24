defmodule MetadataApp.FiltrosDefaultTest do
  use ExUnit.Case, async: true

  alias MetadataApp.FiltrosDefault

  describe "rango_fecha/3 — modos dinámicos (\"actual\"/\"primer_dia_anio\"/\"ultimo_dia_anio\")" do
    test "ignoran cualquier valor guardado — un año viejo da el mismo resultado que nil" do
      valor_viejo = Date.add(Date.utc_today(), -400 * 3)

      for modo <- ["actual", "primer_dia_anio", "ultimo_dia_anio"] do
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

    test "\"primer_dia_anio\" arranca el 1/1 del año EN CURSO, no el de un valor guardado" do
      anio_actual = Date.utc_today().year
      assert {desde, _hasta} = FiltrosDefault.rango_fecha("primer_dia_anio", nil, nil)
      assert DateTime.to_date(desde) == Date.new!(anio_actual, 1, 1)
    end

    test "\"ultimo_dia_anio\" termina el 31/12 del año EN CURSO, no el de un valor guardado" do
      anio_actual = Date.utc_today().year
      assert {_desde, hasta} = FiltrosDefault.rango_fecha("ultimo_dia_anio", nil, nil)
      assert DateTime.to_date(hasta) == Date.new!(anio_actual, 12, 31)
    end
  end

  describe "rango_fecha/3 — modo \"rango\" (única excepción, sí depende de fechas guardadas)" do
    test "usa exactamente desde/hasta, sin recalcular nada" do
      desde = ~D[2026-03-01]
      hasta = ~D[2026-03-15]
      assert {resultado_desde, resultado_hasta} = FiltrosDefault.rango_fecha("rango", desde, hasta)
      assert DateTime.to_date(resultado_desde) == desde
      assert DateTime.to_date(resultado_hasta) == hasta
    end
  end

  describe "descripcion/3 — modos dinámicos" do
    test "describen el período actual, no un valor guardado" do
      valor_viejo = Date.add(Date.utc_today(), -400 * 3)

      for modo <- ["actual", "primer_dia_anio", "ultimo_dia_anio"] do
        assert FiltrosDefault.descripcion(modo, valor_viejo, nil) == FiltrosDefault.descripcion(modo, nil, nil)
      end
    end
  end
end
