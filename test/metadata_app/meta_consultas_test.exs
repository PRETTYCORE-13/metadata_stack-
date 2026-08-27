defmodule MetadataApp.MetaConsultasTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.Repo
  alias MetadataApp.MetaConsultas
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaBusinessProcess.Catalogos.{MetaFixtureCliente, MetaFixtureEquipo}

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp header_vacio(nombre, tipo \\ 1, detalles \\ []) do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => nombre,
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => tipo,
        "detalles" => detalles
      })

    header
  end

  defp campo_referencia(nombre_campo, catalogo_destino) do
    %{
      "schema_context_field" => nombre_campo,
      "schema_context_properties" => %{
        "tipo" => "referencia",
        "catalogo" => catalogo_destino,
        "etiqueta" => nombre_campo,
        "orden" => 1,
        "visible" => true,
        "editable" => true
      }
    }
  end

  defp crear_consulta(catalogo_base) do
    header = header_vacio("consulta_test_#{unique()}", 3)
    {:ok, consulta} = MetaConsultas.crear(header, catalogo_base)
    consulta
  end

  # Bug real (2026-08-27): "inventory_location y sales_unit no permiten
  # filtrar" (branch tenía el mismo problema, no reportado pero mismo
  # código). Los 3 campos de CONTROL branch/inventory_location/sales_unit
  # se guardan SIEMPRE con "tipo" => nil (no vienen de meta_schema_detail,
  # ver sincronizar_campos_control/2) -- campos_elegibles_string/1 leía
  # ese "tipo" crudo, así que nunca los consideraba elegibles pese a ser
  # conceptualmente una referencia. tipo_efectivo/1 resuelve esto en
  # LECTURA (sin backfill de datos ya guardados).
  describe "campos de control branch/inventory_location/sales_unit son elegibles como Parámetro (bug real 2026-08-27)" do
    test "tipo_efectivo/1 resuelve \"referencia\" para los 3, aunque el campo tenga tipo nil guardado" do
      for clave <- ~w(branch inventory_location sales_unit) do
        campo = %{"control" => true, "campo" => clave, "tipo" => nil}
        assert MetaConsultas.tipo_efectivo(campo) == "referencia"
      end
    end

    test "tipo_efectivo/1 NO toca id/estado/trn (no son conceptualmente una referencia)" do
      for clave <- ~w(id estado trn) do
        campo = %{"control" => true, "campo" => clave, "tipo" => nil}
        assert MetaConsultas.tipo_efectivo(campo) == nil
      end
    end

    test "campos_elegibles_string/1 incluye un campo de control inventory_location/sales_unit marcado es_parametro" do
      consulta = %MetadataApp.MetaSchema.Consulta{
        campos: [
          %{"control" => true, "campo" => "inventory_location", "catalogo" => "x", "tipo" => nil, "visible" => true, "es_parametro" => true},
          %{"control" => true, "campo" => "sales_unit", "catalogo" => "x", "tipo" => nil, "visible" => true, "es_parametro" => true},
          %{"control" => true, "campo" => "id", "catalogo" => "x", "tipo" => nil, "visible" => true, "es_parametro" => true}
        ]
      }

      elegibles = MetaConsultas.campos_elegibles_string(consulta) |> Enum.map(& &1["campo"])
      assert "inventory_location" in elegibles
      assert "sales_unit" in elegibles
      refute "id" in elegibles
    end

    test "props_referenciado/2 resuelve el catálogo de sistema real para cada uno de los 3 campos de control" do
      assert %{"catalogo" => "meta_schema_branch"} = MetaConsultas.props_referenciado(%{"control" => true, "campo" => "branch"}, %{})
      assert %{"catalogo" => "meta_schema_inventory_location"} = MetaConsultas.props_referenciado(%{"control" => true, "campo" => "inventory_location"}, %{})
      assert %{"catalogo" => "meta_schema_sales_unit"} = MetaConsultas.props_referenciado(%{"control" => true, "campo" => "sales_unit"}, %{})
    end
  end

  describe "detectar_union/2" do
    test "dirección A: la tabla que se agrega tiene el campo referencia hacia una ya presente" do
      nombre_a = "detectar_a_#{unique()}"
      nombre_b = "detectar_b_#{unique()}"

      header_vacio(nombre_a)
      header_vacio(nombre_b, 1, [campo_referencia("a_id", nombre_a)])

      assert {:ok, union} = MetaConsultas.detectar_union([nombre_a], nombre_b)
      assert union["catalogo_destino"] == nombre_a
      assert union["campo_en_destino"] == "id"
      assert union["campo_en_nuevo"] == "a_id"
    end

    test "dirección B: una tabla ya presente tiene el campo referencia hacia la que se agrega" do
      nombre_a = "detectar_c_#{unique()}"
      nombre_b = "detectar_d_#{unique()}"

      header_vacio(nombre_a, 1, [campo_referencia("b_id", nombre_b)])
      header_vacio(nombre_b)

      assert {:ok, union} = MetaConsultas.detectar_union([nombre_a], nombre_b)
      assert union["catalogo_destino"] == nombre_a
      assert union["campo_en_destino"] == "b_id"
      assert union["campo_en_nuevo"] == "id"
    end

    test "devuelve :sin_union cuando no hay ninguna relación configurada" do
      assert :sin_union = MetaConsultas.detectar_union(["meta_fixture_cliente"], "meta_fixture_equipo")
    end
  end

  describe "motor multi-tabla" do
    # Unión determinística por VALOR (no por id autoincremental, que no
    # tiene por qué coincidir entre dos tablas con secuencias
    # independientes) — meta_fixture_equipo_nombre_equipo se inserta
    # igual a meta_fixture_cliente_nombre a propósito, así el join da
    # exactamente un match sin importar qué otras filas haya en la tabla.
    setup do
      nombre_compartido = "match #{unique()}"

      cliente =
        %MetaFixtureCliente{}
        |> MetaFixtureCliente.changeset(%{
          meta_fixture_cliente_nombre: nombre_compartido,
          meta_fixture_cliente_edad: 40,
          meta_fixture_cliente_venta: Decimal.new("500.00")
        })
        |> Ecto.Changeset.put_change(:insert_guid, guid())
        |> Repo.insert!()

      equipo =
        %MetaFixtureEquipo{}
        |> MetaFixtureEquipo.changeset(%{meta_fixture_equipo_nombre_equipo: nombre_compartido})
        |> Ecto.Changeset.put_change(:insert_guid, guid())
        |> Repo.insert!()

      %{cliente: cliente, equipo: equipo, nombre_compartido: nombre_compartido}
    end

    defp unir_por_nombre(consulta) do
      MetaConsultas.agregar_tabla_manual(
        consulta,
        "meta_fixture_equipo",
        "meta_fixture_equipo_nombre_equipo",
        "meta_fixture_cliente",
        "meta_fixture_cliente_nombre"
      )
    end

    test "agregar_tabla_manual/5 + ejecutar/4 combina campos de las dos tablas con claves namespaced", %{nombre_compartido: nombre_compartido} do
      consulta = crear_consulta("meta_fixture_cliente")
      {:ok, consulta} = unir_por_nombre(consulta)

      assert MetaConsultas.catalogos_presentes(consulta) == ["meta_fixture_cliente", "meta_fixture_equipo"]
      assert Enum.any?(consulta.campos, &(&1["catalogo"] == "meta_fixture_equipo" and &1["campo"] == "meta_fixture_equipo_nombre_equipo"))

      resultado = MetaConsultas.ejecutar(consulta, :sistema)

      fila = Enum.find(resultado.filas, &(&1[:meta_fixture_cliente__meta_fixture_cliente_nombre] == nombre_compartido))
      refute is_nil(fila)
      assert fila[:meta_fixture_equipo__meta_fixture_equipo_nombre_equipo] == nombre_compartido
    end

    test "filtrar por un campo de la tabla UNIDA (no la base) filtra correctamente", %{nombre_compartido: nombre_compartido} do
      consulta = crear_consulta("meta_fixture_cliente")
      {:ok, consulta} = unir_por_nombre(consulta)

      resultado_match =
        MetaConsultas.ejecutar(consulta, :sistema, %{"meta_fixture_equipo_nombre_equipo" => {:ilike, nombre_compartido}})

      assert resultado_match.total_filas == 1
      assert [fila] = resultado_match.filas
      assert fila[:meta_fixture_cliente__meta_fixture_cliente_nombre] == nombre_compartido

      resultado_sin_match =
        MetaConsultas.ejecutar(consulta, :sistema, %{"meta_fixture_equipo_nombre_equipo" => {:ilike, "esto-no-existe-#{unique()}"}})

      assert resultado_sin_match.total_filas == 0
    end

    test "totales suma solo la columna marcada totalizar, con clave namespaced", %{cliente: cliente, nombre_compartido: nombre_compartido} do
      consulta = crear_consulta("meta_fixture_cliente")
      {:ok, consulta} = unir_por_nombre(consulta)

      campos =
        Enum.map(consulta.campos, fn c ->
          if c["catalogo"] == "meta_fixture_cliente" and c["campo"] == "meta_fixture_cliente_edad" do
            Map.put(c, "totalizar", true)
          else
            c
          end
        end)

      {:ok, consulta} = MetaConsultas.actualizar_campos(consulta, campos)
      resultado = MetaConsultas.ejecutar(consulta, :sistema, %{"meta_fixture_cliente_nombre" => {:ilike, nombre_compartido}})

      assert resultado.totales[:meta_fixture_cliente__meta_fixture_cliente_edad] == cliente.meta_fixture_cliente_edad
    end

    test "quitar_ultima_tabla/1 saca la tabla y todos sus campos" do
      consulta = crear_consulta("meta_fixture_cliente")
      {:ok, consulta} = unir_por_nombre(consulta)
      total_con_join = length(consulta.campos)

      {:ok, consulta} = MetaConsultas.quitar_ultima_tabla(consulta)

      assert MetaConsultas.catalogos_presentes(consulta) == ["meta_fixture_cliente"]
      assert length(consulta.campos) < total_con_join
      refute Enum.any?(consulta.campos, &(&1["catalogo"] == "meta_fixture_equipo"))
    end

    test "quitar_ultima_tabla/1 sin tablas relacionadas devuelve error" do
      consulta = crear_consulta("meta_fixture_cliente")
      assert {:error, :no_hay_tablas_para_quitar} = MetaConsultas.quitar_ultima_tabla(consulta)
    end
  end

  describe "alcance de datos (Fase 4, contra catalogo_base)" do
    # Solo hasta acá y no más -- probar de verdad el WHERE branch_id/
    # empresa_id/etc contra una columna real, bajo Ecto.Adapters.SQL.Sandbox,
    # tiene el mismo problema ya documentado en AlcanceDatosPorCatalogoUiTest
    # (DDL de "Alcance de datos" invisible entre conexiones bajo sandbox
    # transaccional) -- la prueba real con datos reales (branch_id
    # existente, filas efectivamente acotadas por sucursal) se corrió a
    # mano contra dev (consulta_croac_masterdata_clientes_baseclientes
    # sobre pty_dsd_cs_clientes, que sí tiene alcance_habilitado: true),
    # mismo criterio que esa otra prueba. Acá solo lo que no depende de
    # ninguna columna real: bypass (:sistema) y deny-by-default (scope nil).
    test "scope :sistema bypassea el alcance; scope nil (anónimo) es deny-by-default" do
      %MetaFixtureCliente{}
      |> MetaFixtureCliente.changeset(%{meta_fixture_cliente_nombre: "alcance nil #{unique()}", meta_fixture_cliente_edad: 1, meta_fixture_cliente_venta: Decimal.new("1.00")})
      |> Ecto.Changeset.put_change(:insert_guid, guid())
      |> Repo.insert!()

      consulta = crear_consulta("meta_fixture_cliente")
      total_sin_alcance = MetaConsultas.contar(consulta, :sistema)
      assert total_sin_alcance >= 1

      {:ok, header} = MetaSchemaContext.actualizar_header(MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente"), %{"alcance_habilitado" => true})

      assert MetaConsultas.contar(consulta, :sistema) == total_sin_alcance
      assert MetaConsultas.contar(consulta, nil) == 0

      resultado = MetaConsultas.ejecutar(consulta, nil)
      assert resultado.filas == []
      assert resultado.total_filas == 0

      {:ok, _} = MetaSchemaContext.actualizar_header(header, %{"alcance_habilitado" => false})
    end
  end
end
