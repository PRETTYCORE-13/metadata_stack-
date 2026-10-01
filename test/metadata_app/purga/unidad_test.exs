defmodule MetadataApp.Purga.UnidadTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.Purga.Unidad
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  defp h(id, nombre, encabezado_id \\ nil),
    do: %{id: id, nombre: nombre, encabezado_id: encabezado_id}

  describe "tablas_de/2" do
    test "maestro solo" do
      assert Unidad.tablas_de("pty_motos", [h(1, "pty_motos")]) == {:ok, ["pty_motos"]}
    end

    test "detalles a varios niveles salen antes que su maestro" do
      headers = [
        h(1, "pty_ped"),
        h(2, "pty_ped_det", 1),
        h(3, "pty_ped_det_lote", 2),
        h(4, "pty_ped_pago", 1),
        h(5, "pty_otro")
      ]

      assert {:ok, tablas} = Unidad.tablas_de("pty_ped", headers)
      assert tablas == ["pty_ped_det_lote", "pty_ped_det", "pty_ped_pago", "pty_ped"]
    end

    test "un detalle no es unidad propia: dice cuál es su maestro raíz" do
      headers = [h(1, "pty_ped"), h(2, "pty_ped_det", 1), h(3, "pty_ped_det_lote", 2)]

      assert Unidad.tablas_de("pty_ped_det_lote", headers) == {:error, {:es_detalle, "pty_ped"}}
    end

    test "una carpeta no es purgable; una consulta y una consulta SQL sí, solas" do
      headers = [
        %{id: 1, nombre: "pty_carpeta_admin", encabezado_id: nil, tipo: 2},
        %{id: 2, nombre: "pty_reporte", encabezado_id: nil, tipo: 3},
        %{id: 3, nombre: "pty_sql_x", encabezado_id: nil, tipo: 4}
      ]

      assert Unidad.tablas_de("pty_carpeta_admin", headers) == {:error, {:no_purgable, 2}}
      assert Unidad.tablas_de("pty_reporte", headers) == {:ok, ["pty_reporte"]}
      assert Unidad.tablas_de("pty_sql_x", headers) == {:ok, ["pty_sql_x"]}

      assert Unidad.unidades_de(headers) == [
               %{maestro: "pty_reporte", tablas: ["pty_reporte"], tipo: 3},
               %{maestro: "pty_sql_x", tablas: ["pty_sql_x"], tipo: 4}
             ]
    end

    test "no existe" do
      assert Unidad.tablas_de("pty_nada", [h(1, "pty_motos")]) == {:error, :no_existe}
    end

    test "rechaza cualquier nombre que no sea pty_*" do
      for nombre <- ["meta_schema_header", "pty_x; drop table y", "PTY_X", "pty-x", ""] do
        assert Unidad.tablas_de(nombre, [h(1, nombre)]) == {:error, :nombre_invalido}
      end
    end
  end

  describe "unidades_de/1" do
    test "un elemento por maestro pty_*, sin detalles sueltos ni catálogos core" do
      headers = [
        h(1, "pty_ped"),
        h(2, "pty_ped_det", 1),
        h(3, "pty_motos"),
        h(4, "meta_fixture_cliente")
      ]

      assert Unidad.unidades_de(headers) == [
               %{maestro: "pty_motos", tablas: ["pty_motos"], tipo: 1},
               %{maestro: "pty_ped", tablas: ["pty_ped_det", "pty_ped"], tipo: 1}
             ]
    end
  end

  describe "migraciones/3" do
    @archivos [
      "20260901000000_crear_pty_marcas_20260901000000.exs",
      "20260902000000_agregar_campos_a_pty_marcas_20260902000000.exs",
      "20260903000000_quitar_color_de_pty_marcas_20260903000000.exs",
      "20260904000000_eliminar_pty_marcas_20260904000000.exs",
      "20260905000000_permitir_nulo_en_pty_marcas_fecha_baja_pty_marcas_20260905000000.exs",
      "20260906000000_indices_unicos_pty_marcas.exs",
      "20260907000000_crear_pty_marcas_v2_20260907000000.exs",
      "20260908000000_agregar_campos_a_pty_marcas_v2_20260908000000.exs",
      "20260909000000_crear_meta_schema_algo.exs"
    ]

    test "toma todas las formas del generador y las manuales, nunca las de pty_marcas_v2" do
      assert Unidad.migraciones(["pty_marcas"], @archivos) == [
               "20260901000000_crear_pty_marcas_20260901000000.exs",
               "20260902000000_agregar_campos_a_pty_marcas_20260902000000.exs",
               "20260903000000_quitar_color_de_pty_marcas_20260903000000.exs",
               "20260904000000_eliminar_pty_marcas_20260904000000.exs",
               "20260905000000_permitir_nulo_en_pty_marcas_fecha_baja_pty_marcas_20260905000000.exs",
               "20260906000000_indices_unicos_pty_marcas.exs"
             ]
    end

    test "maestro y detalle juntos" do
      archivos = [
        "20260901000000_crear_pty_ped_20260901000000.exs",
        "20260901000001_crear_pty_ped_det_20260901000001.exs",
        "20260901000002_crear_pty_pedidos_20260901000002.exs"
      ]

      assert Unidad.migraciones(["pty_ped_det", "pty_ped"], archivos) == Enum.take(archivos, 2)
    end

    test "si coincide con dos tablas conocidas, pertenece a la más larga" do
      archivo = "20260901000000_crear_pty_b_pty_a_20260901000000.exs"

      assert Unidad.migraciones(["pty_a"], [archivo], ["pty_b_pty_a"]) == []
      assert Unidad.migraciones(["pty_b_pty_a"], [archivo], ["pty_a"]) == [archivo]
    end
  end

  test "version/1 toma el prefijo numérico, también con ruta" do
    assert Unidad.version(
             "priv/repo/migrations/20260901000000_crear_pty_marcas_20260901000000.exs"
           ) == 20_260_901_000_000
  end

  describe "contra la base" do
    test "tablas/2 y unidades/1 leen meta_schema_header, incluido un detalle con borrado lógico" do
      sufijo = System.unique_integer([:positive])
      maestro = "pty_purga_unidad_#{sufijo}"
      detalle = "#{maestro}_det"

      {:ok, {header, _}} = MetaSchemaContext.crear_header_con_detalles(attrs(maestro, %{}))

      {:ok, {det, _}} =
        MetaSchemaContext.crear_header_con_detalles(
          attrs(detalle, %{"schema_encabezado_id" => header.id})
        )

      Repo.update_all(from(x in "meta_schema_header", where: x.id == ^det.id),
        set: [delete_guid: "borrado"]
      )

      assert Unidad.tablas(Repo, maestro) == {:ok, [detalle, maestro]}

      assert %{maestro: ^maestro, tablas: [^detalle, ^maestro]} =
               Enum.find(Unidad.unidades(Repo), &(&1.maestro == maestro))
    end
  end

  defp attrs(nombre, extra) do
    Map.merge(
      %{
        "schema_context_name" => nombre,
        "schema_context_label" => nombre,
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => []
      },
      extra
    )
  end
end
