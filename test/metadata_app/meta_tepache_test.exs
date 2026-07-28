defmodule MetadataApp.MetaTepacheTest do
  use ExUnit.Case, async: true

  alias MetadataApp.MetaTepache

  describe "armar_notas/4" do
    test "sin descripcion, automáticos ni problemas" do
      notas = MetaTepache.armar_notas("", ["pty_aly_marcas"], [], [])

      assert notas =~ "**Catálogos incluidos:** pty_aly_marcas"
      assert notas =~ "Sin advertencias."
      refute notas =~ "Incluidos automáticamente"
    end

    test "con descripcion libre, va primero" do
      notas = MetaTepache.armar_notas("Agrego validación de crédito.", ["pty_aly_marcas"], [], [])

      assert String.starts_with?(notas, "Agrego validación de crédito.")
      assert notas =~ "**Catálogos incluidos:** pty_aly_marcas"
    end

    test "con catálogos automáticos" do
      notas = MetaTepache.armar_notas("", ["pty_crm_comando_enc"], ["pty_crm_comando_det"], [])

      assert notas =~ "**Catálogos incluidos:** pty_crm_comando_enc"
      assert notas =~ "**Incluidos automáticamente (detalles/referencias):** pty_crm_comando_det"
    end

    test "con advertencias del validador" do
      problemas = [%{severidad: :advertencia, mensaje: "algo raro"}, %{severidad: :error, mensaje: "algo peor"}]
      notas = MetaTepache.armar_notas("", ["pty_x"], [], problemas)

      assert notas =~ "**Advertencias:**"
      assert notas =~ "- [advertencia] algo raro"
      assert notas =~ "- [error] algo peor"
      refute notas =~ "Sin advertencias."
    end
  end
end
