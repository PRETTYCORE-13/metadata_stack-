defmodule MetadataApp.MetaImportacionDatosTest do
  # SPEC-SYS-0909202602, tarea B1/B2 -- Postgres real, mismo criterio que
  # ParametrosCatalogoTest: MetaFixtureCliente/PedidoPruebaMultinivel/
  # PartidasPruebaMultinivel son catálogos reales, no mocks.
  use MetadataApp.DataCase, async: true

  alias MetadataApp.Repo
  alias MetadataApp.MetaImportacionDatos
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataApp.MetaBusinessProcess.Catalogos.{PedidoPruebaMultinivel, PartidasPruebaMultinivel}

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp fixture_cliente(nombre, edad \\ 30) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(%{meta_fixture_cliente_nombre: nombre, meta_fixture_cliente_edad: edad, meta_fixture_cliente_venta: Decimal.new("1.00")})
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  # Inserts directos (no CatalogoGenerico.crear/Renglones) a propósito:
  # buscar_renglon_existente/4 es una función de consulta pura, se prueba
  # con datos de forma, sin pagar el ciclo completo de alta/motor de
  # estados que no tiene nada que ver con lo que se está probando acá.
  defp fixture_pedido(folio) do
    %PedidoPruebaMultinivel{}
    |> PedidoPruebaMultinivel.changeset(%{pedido_prueba_multinivel_folio: folio})
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp fixture_partida(encabezado_id, renglon_id, producto) do
    %PartidasPruebaMultinivel{}
    |> PartidasPruebaMultinivel.changeset(%{partidas_prueba_multinivel_producto: producto})
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Ecto.Changeset.put_change(:encabezado_id, encabezado_id)
    |> Ecto.Changeset.put_change(:renglon_id, renglon_id)
    |> Repo.insert!()
  end

  describe "buscar_existente/3" do
    test "cero coincidencias -- {:ok, nil}, resultado válido (alta)" do
      assert MetaImportacionDatos.buscar_existente(MetaFixtureCliente, :meta_fixture_cliente_nombre, "Nadie con este nombre") == {:ok, nil}
    end

    test "una coincidencia -- {:ok, registro}" do
      creado = fixture_cliente("Juan Pérez")

      assert {:ok, encontrado} = MetaImportacionDatos.buscar_existente(MetaFixtureCliente, :meta_fixture_cliente_nombre, "Juan Pérez")
      assert encontrado.id == creado.id
    end

    test "más de una coincidencia -- {:error, :identificador_ambiguo}" do
      # Edad distinta a propósito: el índice único real del catálogo es
      # sobre (nombre, edad, venta) combinados -- dos filas idénticas en
      # los 3 campos violarían esa restricción antes de llegar a probar
      # nada. La ambigüedad que importa acá es sobre nombre SOLO.
      fixture_cliente("Duplicado", 20)
      fixture_cliente("Duplicado", 40)

      assert MetaImportacionDatos.buscar_existente(MetaFixtureCliente, :meta_fixture_cliente_nombre, "Duplicado") == {:error, :identificador_ambiguo}
    end

    test "ignora registros dados de baja -- un soft-delete no cuenta como coincidencia" do
      creado = fixture_cliente("Baja")
      creado |> Ecto.Changeset.change(%{delete_guid: guid()}) |> Repo.update!()

      assert MetaImportacionDatos.buscar_existente(MetaFixtureCliente, :meta_fixture_cliente_nombre, "Baja") == {:ok, nil}
    end

    test "coincidencia es exacta, no parcial" do
      fixture_cliente("María López")

      assert MetaImportacionDatos.buscar_existente(MetaFixtureCliente, :meta_fixture_cliente_nombre, "María") == {:ok, nil}
    end
  end

  describe "buscar_renglon_existente/4" do
    test "cero coincidencias dentro de ese encabezado -- {:ok, nil}, resultado válido (alta de renglón)" do
      pedido = fixture_pedido("PED-001")

      assert MetaImportacionDatos.buscar_renglon_existente(PartidasPruebaMultinivel, pedido.id, :partidas_prueba_multinivel_producto, "Nada acá") == {:ok, nil}
    end

    test "una coincidencia -- {:ok, renglon}" do
      pedido = fixture_pedido("PED-002")
      renglon = fixture_partida(pedido.id, 1, "Tornillos")

      assert {:ok, encontrado} = MetaImportacionDatos.buscar_renglon_existente(PartidasPruebaMultinivel, pedido.id, :partidas_prueba_multinivel_producto, "Tornillos")
      assert encontrado.id == renglon.id
    end

    test "el mismo identificador en OTRO encabezado no cuenta -- acotado de verdad a encabezado_id" do
      pedido_a = fixture_pedido("PED-003-A")
      pedido_b = fixture_pedido("PED-003-B")
      _renglon_de_b = fixture_partida(pedido_b.id, 1, "Tuercas")

      assert MetaImportacionDatos.buscar_renglon_existente(PartidasPruebaMultinivel, pedido_a.id, :partidas_prueba_multinivel_producto, "Tuercas") == {:ok, nil}
    end

    test "más de una coincidencia DENTRO del mismo encabezado -- {:error, :identificador_ambiguo}" do
      # partidas_prueba_multinivel_producto tiene su propio índice único
      # (encabezado_id, producto) -- dos renglones genuinamente duplicados
      # en ESE campo no se pueden crear. Para probar la rama de
      # ambigüedad sin pelear contra una restricción real del catálogo,
      # se fuerza la misma fecha_registro en los dos (columna real, sin
      # índice único) -- el criterio de "más de uno" es el mismo sin
      # importar qué campo se use para buscar.
      pedido = fixture_pedido("PED-004")
      fecha = ~U[2026-01-01 10:00:00Z]
      r1 = fixture_partida(pedido.id, 1, "Producto A")
      r2 = fixture_partida(pedido.id, 2, "Producto B")
      r1 |> Ecto.Changeset.change(%{fecha_registro: fecha}) |> Repo.update!()
      r2 |> Ecto.Changeset.change(%{fecha_registro: fecha}) |> Repo.update!()

      assert MetaImportacionDatos.buscar_renglon_existente(PartidasPruebaMultinivel, pedido.id, :fecha_registro, fecha) == {:error, :identificador_ambiguo}
    end

    test "ignora renglones dados de baja" do
      pedido = fixture_pedido("PED-005")
      renglon = fixture_partida(pedido.id, 1, "Descontinuado")
      renglon |> Ecto.Changeset.change(%{delete_guid: guid()}) |> Repo.update!()

      assert MetaImportacionDatos.buscar_renglon_existente(PartidasPruebaMultinivel, pedido.id, :partidas_prueba_multinivel_producto, "Descontinuado") == {:ok, nil}
    end
  end
end
