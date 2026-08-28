defmodule MetadataApp.MetaConsultasTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.Repo
  alias MetadataApp.MetaConsultas
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaBusinessProcess.Catalogos.{MetaFixtureCliente, MetaFixtureEquipo}
  alias MetadataApp.Autenticacion.{Branch, Empresa}

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

  defp fixture_cliente(nombre, edad) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(%{meta_fixture_cliente_nombre: nombre, meta_fixture_cliente_edad: edad, meta_fixture_cliente_venta: Decimal.new("1.00")})
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp header_detalle_de(nombre, maestro_id, detalles \\ []) do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => nombre,
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "schema_encabezado_id" => maestro_id,
        "detalles" => detalles
      })

    header
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

  # Maestro-detalle (R3) se autodetecta APARTE de "referencia" -- ver
  # detectar_union_maestro_detalle/2 en MetaConsultas. Bug real 2026-08-26
  # que motiva esto: un admin unió a mano un maestro con su detalle por
  # "id"="id" (única opción que ofrecía el editor manual antes de este
  # cambio) -- traía 1 fila por maestro en vez del fan-out real.
  describe "detectar_union/2 — maestro-detalle (R3)" do
    test "dirección A: la tabla que se agrega es detalle de una ya presente" do
      maestro = header_vacio("md_maestro_a_#{unique()}")
      detalle_nombre = "md_detalle_a_#{unique()}"
      header_detalle_de(detalle_nombre, maestro.id)

      assert {:ok, union} = MetaConsultas.detectar_union([maestro.schema_context_name], detalle_nombre)
      assert union["catalogo_destino"] == maestro.schema_context_name
      assert union["campo_en_destino"] == "id"
      assert union["campo_en_nuevo"] == "encabezado_id"
    end

    test "dirección B: una tabla ya presente es detalle de la que se agrega" do
      maestro_nombre = "md_maestro_b_#{unique()}"
      maestro = header_vacio(maestro_nombre)
      detalle_nombre = "md_detalle_b_#{unique()}"
      header_detalle_de(detalle_nombre, maestro.id)

      assert {:ok, union} = MetaConsultas.detectar_union([detalle_nombre], maestro_nombre)
      assert union["catalogo_destino"] == detalle_nombre
      assert union["campo_en_destino"] == "encabezado_id"
      assert union["campo_en_nuevo"] == "id"
    end

    test "tiene prioridad sobre una relación \"referencia\" configurada entre las mismas dos tablas" do
      maestro_nombre = "md_maestro_c_#{unique()}"
      maestro = header_vacio(maestro_nombre)
      detalle_nombre = "md_detalle_c_#{unique()}"
      header_detalle_de(detalle_nombre, maestro.id, [campo_referencia("maestro_id", maestro_nombre)])

      assert {:ok, union} = MetaConsultas.detectar_union([maestro_nombre], detalle_nombre)
      assert union["campo_en_nuevo"] == "encabezado_id"
    end

    test "devuelve :sin_union cuando ninguna de las dos es detalle de la otra" do
      maestro_nombre = "md_maestro_d_#{unique()}"
      header_vacio(maestro_nombre)
      otro_nombre = "md_otro_d_#{unique()}"
      header_vacio(otro_nombre)

      assert :sin_union = MetaConsultas.detectar_union([maestro_nombre], otro_nombre)
    end
  end

  describe "campos_disponibles_para_union/1" do
    test "incluye \"encabezado_id\" cuando el catálogo es detalle de un maestro" do
      maestro = header_vacio("cdu_maestro_#{unique()}")
      detalle_nombre = "cdu_detalle_#{unique()}"
      header_detalle_de(detalle_nombre, maestro.id)

      assert "encabezado_id" in MetaConsultas.campos_disponibles_para_union(detalle_nombre)
    end

    test "no incluye \"encabezado_id\" para un catálogo que no es detalle de nada" do
      nombre = "cdu_normal_#{unique()}"
      header_vacio(nombre)

      refute "encabezado_id" in MetaConsultas.campos_disponibles_para_union(nombre)
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

  # Bug real 2026-08-27 (reporte "Clientes Core": columna "U.Venta" mostraba
  # el id crudo de la FK en vez de "Prev-Uriel"/"Prev-Jazmin") -- ejecutar/6
  # solo resolvía a nombre los 3 campos de CONTROL (branch/inventory_location/
  # sales_unit), nunca un campo "tipo" => "referencia" de negocio cualquiera.
  # meta_fixture_cliente_sucursal_id (agregado 2026-08-26, referencia hacia
  # meta_schema_branch, sistema) es el fixture real para probarlo.
  describe "ejecutar/6 resuelve un campo \"referencia\" a su etiqueta (bug real 2026-08-27)" do
    test "columna referencia hacia un catálogo de sistema muestra el nombre, no el id crudo" do
      {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa consulta test #{unique()}"}) |> Repo.insert()
      {:ok, branch} = %Branch{} |> Branch.changeset(%{empresa_id: empresa.id, branch_name: "Sucursal #{unique()}"}) |> Repo.insert()

      nombre_cliente = "referencia_test_#{unique()}"

      %MetaFixtureCliente{}
      |> MetaFixtureCliente.changeset(%{
        meta_fixture_cliente_nombre: nombre_cliente,
        meta_fixture_cliente_edad: 30,
        meta_fixture_cliente_venta: Decimal.new("100.00"),
        meta_fixture_cliente_sucursal_id: branch.id
      })
      |> Ecto.Changeset.put_change(:insert_guid, guid())
      |> Repo.insert!()

      consulta = crear_consulta("meta_fixture_cliente")
      resultado = MetaConsultas.ejecutar(consulta, :sistema)

      fila = Enum.find(resultado.filas, &(&1[:meta_fixture_cliente__meta_fixture_cliente_nombre] == nombre_cliente))
      refute is_nil(fila)
      assert fila[:meta_fixture_cliente__meta_fixture_cliente_sucursal_id] == branch.branch_name
    end
  end

  # "Orden de resultados" (R1 admin, 2026-08-27) -- pedido explícito:
  # ordenar el reporte por varias columnas en prioridad (ej. sucursal,
  # unit sale, nombre del cliente), cualquiera sea su visibilidad.
  describe "ejecutar/6 respeta orden_por (Orden de resultados)" do
    test "ordena por la primera columna y desempata con la segunda" do
      prefijo = "orden_#{unique()}"
      # edad IGUAL en las dos primeras a propósito -- si la 2da columna
      # (nombre) no desempata, el orden entre ellas queda indefinido y el
      # test sería flaky.
      fixture_cliente("#{prefijo}-b", 30)
      fixture_cliente("#{prefijo}-a", 30)
      fixture_cliente("#{prefijo}-z", 20)

      consulta = crear_consulta("meta_fixture_cliente")

      {:ok, consulta} =
        MetaConsultas.actualizar_orden_por(consulta, [
          %{"catalogo" => "meta_fixture_cliente", "campo" => "meta_fixture_cliente_edad", "direccion" => "asc"},
          %{"catalogo" => "meta_fixture_cliente", "campo" => "meta_fixture_cliente_nombre", "direccion" => "asc"}
        ])

      resultado = MetaConsultas.ejecutar(consulta, :sistema)

      nombres =
        resultado.filas
        |> Enum.map(& &1[:meta_fixture_cliente__meta_fixture_cliente_nombre])
        |> Enum.filter(&String.starts_with?(&1, prefijo))

      assert nombres == ["#{prefijo}-z", "#{prefijo}-a", "#{prefijo}-b"]
    end

    test "una entrada de orden_por que ya no matchea ningún campo se ignora, no revienta" do
      consulta = crear_consulta("meta_fixture_cliente")

      {:ok, consulta} =
        MetaConsultas.actualizar_orden_por(consulta, [
          %{"catalogo" => "meta_fixture_cliente", "campo" => "campo_que_no_existe", "direccion" => "asc"}
        ])

      assert %{filas: _} = MetaConsultas.ejecutar(consulta, :sistema)
    end
  end
end
