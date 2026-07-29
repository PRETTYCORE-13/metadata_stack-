defmodule MetadataApp.MetaPublicadorTest do
  use ExUnit.Case, async: false

  alias MetadataApp.MetaPublicador

  describe "armar_bundle/1" do
    test "sin archivos encontrados para el/los catálogo(s)" do
      assert {:error, mensaje} = MetaPublicador.armar_bundle(["catalogo_que_no_existe_nunca_jamas"])
      assert mensaje =~ "Ningún archivo encontrado"
    end
  end

  # PATH vacío simula "gh"/"tar" no instalado o no en el PATH del proceso --
  # mismo escenario real que tumbaba el LiveView (:enoent) antes del fix.
  # async: false porque muta la variable de entorno PATH del proceso BEAM
  # entero, no solo de este test.
  describe "cuando gh/tar no están en el PATH" do
    setup do
      path_original = System.get_env("PATH")
      System.put_env("PATH", "")
      on_exit(fn -> System.put_env("PATH", path_original || "") end)
      :ok
    end

    test "persistir_bundle/2 devuelve error legible en vez de crashear" do
      assert {:error, mensaje} = MetaPublicador.persistir_bundle(["catalogo_x"], "bundle-inexistente.tar.gz")
      assert mensaje =~ ~s(No se pudo ejecutar "gh")
    end

    test "disparar_deploy/2 devuelve error legible y limpia los archivos temporales" do
      bundle_path = Path.join(System.tmp_dir!(), "meta-publicador-test-#{System.unique_integer([:positive])}.tar.gz")
      File.write!(bundle_path, "contenido de prueba")

      assert {:error, mensaje} = MetaPublicador.disparar_deploy(["catalogo_x"], bundle_path)
      assert mensaje =~ ~s(No se pudo ejecutar "gh")
      refute File.exists?(bundle_path)
      refute File.exists?(bundle_path <> ".b64")
    end
  end
end
