defmodule MetadataApp.BusinessProcessBuilder.CatalogoGeneradorTest do
  use MetadataApp.DataCase, async: false

  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerador
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  describe "generar_migracion_drop/1 (SPEC-SYS-1809202601, design.md §1, R1)" do
    test "escribe la migración de DROP por nombre, sin exigir que exista un header local" do
      nombre = "catalogo_huerfano_test_#{System.unique_integer([:positive])}"
      refute MetaSchemaContext.obtener_header_por_nombre(nombre)

      path = CatalogoGenerador.generar_migracion_drop(nombre)
      on_exit(fn -> File.rm(path) end)

      assert File.exists?(path)
      contenido = File.read!(path)
      assert contenido =~ "drop_if_exists table(:#{nombre})"
      assert contenido =~ "purgar_metadata_por_nombre(\"#{nombre}\")"
      # up/down (no change/0) a propósito -- ver comentario de la función:
      # purgar_metadata_por_nombre/1 no es reversible.
      assert contenido =~ "def up do"
      assert contenido =~ "def down do"
    end

    test "el nombre de archivo/módulo es único incluso llamada dos veces seguidas para el mismo catálogo" do
      nombre = "catalogo_huerfano_test_#{System.unique_integer([:positive])}"

      path1 = CatalogoGenerador.generar_migracion_drop(nombre)
      path2 = CatalogoGenerador.generar_migracion_drop(nombre)
      on_exit(fn -> File.rm(path1); File.rm(path2) end)

      refute path1 == path2
      assert File.exists?(path1)
      assert File.exists?(path2)
    end
  end

  describe "purgar_metadata_por_nombre/1 (ya pública, confirmando el comportamiento del que depende R1)" do
    test "no-opea sin romper nada si el header no existe" do
      nombre = "catalogo_que_no_existe_nunca_#{System.unique_integer([:positive])}"
      assert :ok = CatalogoGenerador.purgar_metadata_por_nombre(nombre)
    end
  end
end
