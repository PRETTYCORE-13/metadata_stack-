defmodule MetadataApp.SeedMasterdataTest do
  use ExUnit.Case, async: true

  alias MetadataApp.SeedMasterdata

  describe "validar_catalogo/1 (R5)" do
    test "acepta pty_* y demo100_*" do
      assert SeedMasterdata.validar_catalogo("pty_mat_fabricante") == :ok
      assert SeedMasterdata.validar_catalogo("demo100_algo") == :ok
    end

    test "rechaza cualquier otro nombre, incluido meta_schema_*" do
      assert {:error, _} = SeedMasterdata.validar_catalogo("meta_schema_header")
      assert {:error, _} = SeedMasterdata.validar_catalogo("meta_schema_usuario")
      assert {:error, _} = SeedMasterdata.validar_catalogo("otra_tabla")
    end
  end

  describe "orden_topologico/2 — sin dependencias" do
    test "cualquier orden es válido cuando ningún catálogo referencia a otro" do
      grafo = %{"a" => MapSet.new(), "b" => MapSet.new(), "c" => MapSet.new()}

      assert {:ok, orden_carga} = SeedMasterdata.orden_topologico(grafo, :carga)
      assert {:ok, orden_borrado} = SeedMasterdata.orden_topologico(grafo, :borrado)
      assert Enum.sort(orden_carga) == ["a", "b", "c"]
      assert Enum.sort(orden_borrado) == ["a", "b", "c"]
    end
  end

  describe "orden_topologico/2 — cadena simple A→B→C (A referencia a B, B referencia a C)" do
    setup do
      %{grafo: %{"a" => MapSet.new(["b"]), "b" => MapSet.new(["c"]), "c" => MapSet.new()}}
    end

    test ":carga deja las dependencias primero — C, B, A en ese orden", %{grafo: grafo} do
      assert {:ok, ["c", "b", "a"]} = SeedMasterdata.orden_topologico(grafo, :carga)
    end

    test ":borrado es el inverso exacto — A, B, C en ese orden", %{grafo: grafo} do
      assert {:ok, ["a", "b", "c"]} = SeedMasterdata.orden_topologico(grafo, :borrado)
    end
  end

  describe "orden_topologico/2 — dependencias compartidas (varios catálogos referencian al mismo)" do
    test "el catálogo compartido sale antes que todos sus dependientes en :carga" do
      # material_gamas y material_precios referencian a material (mismo
      # patrón real: pty_dsd_mat_material_gamas/precios -> pty_dsd_mat_material)
      grafo = %{
        "material" => MapSet.new(),
        "material_gamas" => MapSet.new(["material"]),
        "material_precios" => MapSet.new(["material"])
      }

      assert {:ok, orden} = SeedMasterdata.orden_topologico(grafo, :carga)
      indice_material = Enum.find_index(orden, &(&1 == "material"))
      indice_gamas = Enum.find_index(orden, &(&1 == "material_gamas"))
      indice_precios = Enum.find_index(orden, &(&1 == "material_precios"))

      assert indice_material < indice_gamas
      assert indice_material < indice_precios
    end
  end

  describe "orden_topologico/2 — ciclo real" do
    test "devuelve {:error, :ciclo, catalogos_involucrados}, excluyendo nodos independientes" do
      grafo = %{"a" => MapSet.new(["b"]), "b" => MapSet.new(["a"]), "c" => MapSet.new()}

      assert {:error, :ciclo, involucrados} = SeedMasterdata.orden_topologico(grafo, :carga)
      assert Enum.sort(involucrados) == ["a", "b"]
      refute "c" in involucrados
    end

    test "detecta un ciclo más largo (a->b->c->a)" do
      grafo = %{"a" => MapSet.new(["b"]), "b" => MapSet.new(["c"]), "c" => MapSet.new(["a"])}

      assert {:error, :ciclo, involucrados} = SeedMasterdata.orden_topologico(grafo, :borrado)
      assert Enum.sort(involucrados) == ["a", "b", "c"]
    end
  end
end
