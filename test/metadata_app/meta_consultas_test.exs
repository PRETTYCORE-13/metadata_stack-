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

      resultado = MetaConsultas.ejecutar(consulta)

      fila = Enum.find(resultado.filas, &(&1[:meta_fixture_cliente__meta_fixture_cliente_nombre] == nombre_compartido))
      refute is_nil(fila)
      assert fila[:meta_fixture_equipo__meta_fixture_equipo_nombre_equipo] == nombre_compartido
    end

    test "filtrar por un campo de la tabla UNIDA (no la base) filtra correctamente", %{nombre_compartido: nombre_compartido} do
      consulta = crear_consulta("meta_fixture_cliente")
      {:ok, consulta} = unir_por_nombre(consulta)

      resultado_match =
        MetaConsultas.ejecutar(consulta, %{"meta_fixture_equipo_nombre_equipo" => {:ilike, nombre_compartido}})

      assert resultado_match.total_filas == 1
      assert [fila] = resultado_match.filas
      assert fila[:meta_fixture_cliente__meta_fixture_cliente_nombre] == nombre_compartido

      resultado_sin_match =
        MetaConsultas.ejecutar(consulta, %{"meta_fixture_equipo_nombre_equipo" => {:ilike, "esto-no-existe-#{unique()}"}})

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
      resultado = MetaConsultas.ejecutar(consulta, %{"meta_fixture_cliente_nombre" => {:ilike, nombre_compartido}})

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
end
