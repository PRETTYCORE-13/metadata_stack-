defmodule MetadataApp.BusinessProcessBuilder.DependenciasReferenciaTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerico}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}
  alias MetadataApp.MetaBusinessProcess.Catalogos.{MetaFixtureCliente, MetaFixtureEquipo}

  defp unique, do: System.unique_integer([:positive])
  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp campo(nombre, tipo, extra) do
    %{
      "schema_context_field" => nombre,
      "schema_context_properties" =>
        Map.merge(%{"etiqueta" => nombre, "tipo" => tipo, "orden" => 0, "visible" => true, "editable" => true}, extra)
    }
  end

  # Catálogo sintético campo_a → campo_b → campo_c → campo_d (solo
  # metadata — meta_schema_header/meta_schema_detail, nunca una tabla
  # física) para ejercitar el MOTOR de dependencias sin depender de
  # ningún catálogo de negocio real.
  defp crear_cadena(sufijo) do
    nombre = "cascada_test_#{sufijo}"

    {:ok, {_header, detalles}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Cascada Test #{sufijo}",
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => [
          campo("campo_a", "referencia", %{"catalogo" => "otro_destino"}),
          campo("campo_b", "referencia", %{
            "catalogo" => "otro_destino",
            "dependencias" => [%{"campo_padre" => "campo_a", "campo_remoto" => "x"}]
          }),
          campo("campo_c", "referencia", %{
            "catalogo" => "otro_destino",
            "dependencias" => [%{"campo_padre" => "campo_b", "campo_remoto" => "x"}]
          }),
          campo("campo_d", "referencia", %{
            "catalogo" => "otro_destino",
            "dependencias" => [%{"campo_padre" => "campo_c", "campo_remoto" => "x"}]
          })
        ]
      })

    {nombre, detalles}
  end

  describe "descendientes/2" do
    test "cadena de 3+ niveles: el nivel 1 arrastra a TODOS, directa o transitivamente" do
      {catalogo, _detalles} = crear_cadena(unique())

      assert MetaSchemaContext.descendientes(catalogo, "campo_a") |> Enum.sort() == ["campo_b", "campo_c", "campo_d"]
      assert MetaSchemaContext.descendientes(catalogo, "campo_b") |> Enum.sort() == ["campo_c", "campo_d"]
      assert MetaSchemaContext.descendientes(catalogo, "campo_c") == ["campo_d"]
      assert MetaSchemaContext.descendientes(catalogo, "campo_d") == []
    end
  end

  describe "limpiar_descendientes/3" do
    test "vacía en cascada a todos los descendientes, deja intactos al resto" do
      {catalogo, _detalles} = crear_cadena(unique())
      valores = %{"campo_a" => "1", "campo_b" => "2", "campo_c" => "3", "campo_d" => "4"}

      resultado = MetaSchemaContext.limpiar_descendientes(catalogo, "campo_b", valores)

      assert resultado["campo_a"] == "1"
      assert resultado["campo_b"] == "2"
      assert resultado["campo_c"] == ""
      assert resultado["campo_d"] == ""
    end
  end

  describe "validar_sin_ciclo/3" do
    test "cadena válida se acepta" do
      {catalogo, _detalles} = crear_cadena(unique())
      assert MetaSchemaContext.validar_sin_ciclo(catalogo, "campo_nuevo", [%{"campo_padre" => "campo_d"}]) == :ok
    end

    test "rechaza depender directamente de sí mismo" do
      {catalogo, _detalles} = crear_cadena(unique())
      assert {:error, motivo} = MetaSchemaContext.validar_sin_ciclo(catalogo, "campo_a", [%{"campo_padre" => "campo_a"}])
      assert motivo =~ "campo_a"
    end

    test "rechaza ciclo indirecto (campo_a depende de campo_d, que ya depende de campo_a a través de b y c)" do
      {catalogo, _detalles} = crear_cadena(unique())
      assert {:error, motivo} = MetaSchemaContext.validar_sin_ciclo(catalogo, "campo_a", [%{"campo_padre" => "campo_d"}])
      assert motivo =~ "campo_a"
    end
  end

  describe "resolver_filtros/3" do
    test "sin valor del padre obligatorio, queda deshabilitado con mensaje" do
      props = %{"dependencias" => [%{"campo_padre" => "estado_id", "campo_remoto" => "estado_id", "obligatorio" => true}]}
      assert {:disabled, _mensaje} = MetaSchemaContext.resolver_filtros(props, %{})
    end

    test "con valor del padre, arma el mapa de filtros" do
      props = %{"dependencias" => [%{"campo_padre" => "estado_id", "campo_remoto" => "estado_id", "obligatorio" => true}]}
      assert {:ok, %{"estado_id" => "5"}} = MetaSchemaContext.resolver_filtros(props, %{"estado_id" => "5"})
    end

    test "varias dependencias (AND) — todas tienen que resolverse antes de traer opciones" do
      props = %{
        "dependencias" => [
          %{"campo_padre" => "empresa_id", "campo_remoto" => "empresa_id", "obligatorio" => true},
          %{"campo_padre" => "almacen_id", "campo_remoto" => "almacen_id", "obligatorio" => true}
        ]
      }

      assert {:disabled, _} = MetaSchemaContext.resolver_filtros(props, %{"empresa_id" => "1"})

      assert {:ok, %{"empresa_id" => "1", "almacen_id" => "2"}} =
               MetaSchemaContext.resolver_filtros(props, %{"empresa_id" => "1", "almacen_id" => "2"})
    end

    test "dependencia no obligatoria sin valor del padre no bloquea, solo no filtra por ella" do
      props = %{"dependencias" => [%{"campo_padre" => "estado_id", "campo_remoto" => "estado_id", "obligatorio" => false}]}
      assert {:ok, %{}} = MetaSchemaContext.resolver_filtros(props, %{})
    end
  end

  describe "CatalogoGenerico.opciones_referencia/2 — filtros contra datos reales" do
    test "filtra el catálogo destino por el valor indicado" do
      sufijo = unique()

      %MetaFixtureCliente{}
      |> MetaFixtureCliente.changeset(%{
        meta_fixture_cliente_nombre: "match #{sufijo}",
        meta_fixture_cliente_edad: 99,
        meta_fixture_cliente_venta: Decimal.new("1")
      })
      |> Ecto.Changeset.change(%{insert_guid: guid()})
      |> Repo.insert!()

      %MetaFixtureCliente{}
      |> MetaFixtureCliente.changeset(%{
        meta_fixture_cliente_nombre: "no coincide #{sufijo}",
        meta_fixture_cliente_edad: 1,
        meta_fixture_cliente_venta: Decimal.new("1")
      })
      |> Ecto.Changeset.change(%{insert_guid: guid()})
      |> Repo.insert!()

      opciones =
        CatalogoGenerico.opciones_referencia(
          %{"catalogo" => "meta_fixture_cliente", "campos_acompanamiento" => ["meta_fixture_cliente_nombre"]},
          %{"meta_fixture_cliente_edad" => 99}
        )

      etiquetas = Enum.map(opciones, fn {_id, etiqueta} -> etiqueta end)
      assert Enum.any?(etiquetas, &(&1 =~ "match #{sufijo}"))
      refute Enum.any?(etiquetas, &(&1 =~ "no coincide #{sufijo}"))
    end
  end

  describe "validar_dependencias_referencia/2 — integridad al guardar un registro real" do
    setup do
      header = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")
      detalle_edad = Repo.get_by!(Detail, meta_schema_header_id: header.id, schema_context_field: "meta_fixture_cliente_edad")

      # Reusa el campo entero "edad" del fixture como si fuera una
      # "referencia" a meta_fixture_equipo, solo para este test — el motor
      # de dependencias no le pide nada a la columna física (sigue siendo
      # :integer real), solo a la METADATA, así que este atajo ejercita el
      # camino real (MetaCatalogoGenerico.changeset/2 →
      # MetaSchemaContext.validar_dependencias_referencia/2) sin tener que
      # levantar un catálogo de negocio nuevo.
      props =
        detalle_edad.schema_context_properties
        |> Map.put("tipo", "referencia")
        |> Map.put("catalogo", "meta_fixture_equipo")
        |> Map.put("dependencias", [
          %{"campo_padre" => "meta_fixture_cliente_nombre", "campo_remoto" => "meta_fixture_equipo_nombre_equipo"}
        ])

      detalle_edad |> Ecto.Changeset.change(%{schema_context_properties: props}) |> Repo.update!()

      :ok
    end

    test "acepta cuando el destino cumple el filtro del padre" do
      sufijo = unique()

      equipo =
        %MetaFixtureEquipo{}
        |> MetaFixtureEquipo.changeset(%{meta_fixture_equipo_nombre_equipo: "coincide #{sufijo}"})
        |> Ecto.Changeset.change(%{insert_guid: guid()})
        |> Repo.insert!()

      changeset =
        MetaFixtureCliente.changeset(%MetaFixtureCliente{}, %{
          meta_fixture_cliente_nombre: "coincide #{sufijo}",
          meta_fixture_cliente_edad: equipo.id,
          meta_fixture_cliente_venta: Decimal.new("1")
        })

      assert changeset.valid?
    end

    test "rechaza cuando el destino NO cumple el filtro del padre (no confía en lo que mandó el cliente)" do
      sufijo = unique()

      equipo =
        %MetaFixtureEquipo{}
        |> MetaFixtureEquipo.changeset(%{meta_fixture_equipo_nombre_equipo: "coincide #{sufijo}"})
        |> Ecto.Changeset.change(%{insert_guid: guid()})
        |> Repo.insert!()

      changeset =
        MetaFixtureCliente.changeset(%MetaFixtureCliente{}, %{
          meta_fixture_cliente_nombre: "otro nombre #{sufijo}",
          meta_fixture_cliente_edad: equipo.id,
          meta_fixture_cliente_venta: Decimal.new("1")
        })

      refute changeset.valid?
      assert "el valor seleccionado no corresponde a la selección anterior" in errors_on(changeset).meta_fixture_cliente_edad
    end

    test "sin valor en el campo padre, no rechaza (nada que validar todavía)" do
      sufijo = unique()

      equipo =
        %MetaFixtureEquipo{}
        |> MetaFixtureEquipo.changeset(%{meta_fixture_equipo_nombre_equipo: "coincide #{sufijo}"})
        |> Ecto.Changeset.change(%{insert_guid: guid()})
        |> Repo.insert!()

      changeset =
        MetaFixtureCliente.changeset(%MetaFixtureCliente{}, %{
          meta_fixture_cliente_edad: equipo.id,
          meta_fixture_cliente_venta: Decimal.new("1")
        })

      # Sin "meta_fixture_cliente_nombre" el changeset ya es inválido por
      # validate_required de siempre — lo que este test confirma es que
      # NO aparece, encima, el error de dependencia (nada que comparar
      # todavía, fail-safe).
      refute "el valor seleccionado no corresponde a la selección anterior" in (errors_on(changeset)[:meta_fixture_cliente_edad] || [])
    end
  end
end
