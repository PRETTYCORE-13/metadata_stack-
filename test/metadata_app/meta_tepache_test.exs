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

  describe "catalogos_en_bundle/1" do
    # El tar.exe nativo de Windows termina cada línea de "-tzf" en "\r\n" --
    # sin el String.trim/1 por línea, "nombres" volvía [] (visto real:
    # aplicar_import/1 corrió sin registrar_permisos ni detectar campos
    # removidos porque no encontraba ningún ".meta.json" en el listado).
    test "detecta los catálogos sin importar el line ending que use el tar del sistema" do
      dir = System.tmp_dir!()
      catalogo = "catalogo_bundle_test_#{System.unique_integer([:positive])}"
      meta_nombre = "#{catalogo}.meta.json"
      meta_path = Path.join(dir, meta_nombre)
      bundle_path = Path.join(dir, "bundle-test-#{System.unique_integer([:positive])}.tar.gz")

      File.write!(meta_path, "{}")
      {_salida, 0} = System.cmd("tar", ["-czf", bundle_path, "-C", dir, meta_nombre])

      on_exit(fn ->
        File.rm(meta_path)
        File.rm(bundle_path)
      end)

      assert {:ok, [^catalogo]} = MetaTepache.catalogos_en_bundle(bundle_path)
    end
  end
end
