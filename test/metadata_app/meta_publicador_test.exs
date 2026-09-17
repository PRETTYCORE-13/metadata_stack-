defmodule MetadataApp.MetaPublicadorTest do
  use ExUnit.Case, async: false

  alias MetadataApp.MetaPublicador

  describe "armar_bundle/1" do
    test "sin archivos encontrados para el/los catálogo(s)" do
      assert {:error, mensaje} = MetaPublicador.armar_bundle(["catalogo_que_no_existe_nunca_jamas"])
      assert mensaje =~ "Ningún archivo encontrado"
    end

    # SPEC-SYS-1009202602, design.md §13 (R67) -- rutas_de/1 (privada)
    # ahora suma priv/repo/catalogos/<catalogo>.endpoint.json si existe.
    # Se prueba indirecto vía armar_bundle/1: un catálogo sin NINGÚN otro
    # archivo (.ex/meta/motor/plantillas/migración) pero CON un
    # .endpoint.json ya no debe caer en "Ningún archivo encontrado".
    test "incluye <catalogo>.endpoint.json si existe (aunque no haya ningún otro archivo)" do
      nombre = "meta_publicador_endpoint_test_#{System.unique_integer([:positive])}"
      archivo = Path.join("priv/repo/catalogos", "#{nombre}.endpoint.json")
      File.write!(archivo, Jason.encode!(%{"catalogo" => nombre, "eliminado" => true}))
      on_exit(fn -> File.rm(archivo) end)

      case MetaPublicador.armar_bundle([nombre]) do
        {:ok, bundle_path} -> File.rm(bundle_path)
        {:error, mensaje} -> refute mensaje =~ "Ningún archivo encontrado"
      end
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
      bundle_path = Path.join(System.tmp_dir!(), "meta-publicador-test-#{System.unique_integer([:positive])}.tar.gz")
      File.write!(bundle_path, "contenido de prueba")

      on_exit(fn ->
        File.rm(bundle_path)
        File.rm(Path.join(Path.dirname(bundle_path), "bundle.tar.gz"))
      end)

      assert {:error, mensaje} = MetaPublicador.persistir_bundle(["catalogo_x"], bundle_path)
      assert mensaje =~ ~s(No se pudo ejecutar "gh")
    end

    test "disparar_deploy/3 devuelve error legible y limpia los archivos temporales" do
      bundle_path = Path.join(System.tmp_dir!(), "meta-publicador-test-#{System.unique_integer([:positive])}.tar.gz")
      File.write!(bundle_path, "contenido de prueba")

      assert {:error, mensaje} = MetaPublicador.disparar_deploy("crm", ["catalogo_x"], bundle_path)
      assert mensaje =~ ~s(No se pudo ejecutar "gh")
      refute File.exists?(bundle_path)
      refute File.exists?(bundle_path <> ".b64")
    end
  end
end
