defmodule MetadataApp.FiltrosDefaultTest do
  use ExUnit.Case, async: true

  alias MetadataApp.FiltrosDefault

  describe "rango_fecha/3 — modo \"actual\"" do
    test "usa siempre Date.utc_today(), sin importar el valor guardado" do
      hoy = Date.utc_today()
      valor_viejo = Date.add(hoy, -30)

      assert FiltrosDefault.rango_fecha("actual", nil, nil) ==
               FiltrosDefault.rango_fecha("actual", valor_viejo, nil)
    end

    test "cubre el día completo de hoy (00:00:00 a 23:59:59 UTC)" do
      hoy = Date.utc_today()

      assert {desde, hasta} = FiltrosDefault.rango_fecha("actual", nil, nil)
      assert DateTime.to_date(desde) == hoy
      assert DateTime.to_date(hasta) == hoy
      assert desde.time_zone == "Etc/UTC"
    end
  end

  describe "valor_default_para_modo/1" do
    test "\"actual\" no precarga nada — no tiene calendario, es dinámico" do
      assert FiltrosDefault.valor_default_para_modo("actual") == nil
    end
  end

  describe "descripcion/3 — modo \"actual\"" do
    test "describe el día de hoy, no un valor guardado" do
      valor_viejo = Date.add(Date.utc_today(), -30)
      assert FiltrosDefault.descripcion("actual", valor_viejo, nil) == FiltrosDefault.descripcion("actual", nil, nil)
    end
  end
end
