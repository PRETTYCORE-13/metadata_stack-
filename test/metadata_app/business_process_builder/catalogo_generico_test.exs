defmodule MetadataApp.BusinessProcessBuilder.CatalogoGenericoTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  # 30 clientes, insertados en orden -- suficiente para tener 2 páginas
  # completas de 25 y probar límite/offset de verdad.
  defp fixture_clientes(cantidad) do
    for _ <- 1..cantidad do
      %MetaFixtureCliente{}
      |> MetaFixtureCliente.changeset(%{
        meta_fixture_cliente_nombre: "paginacion #{unique()}",
        meta_fixture_cliente_edad: 30,
        meta_fixture_cliente_venta: Decimal.new("100.00")
      })
      |> put_change(:insert_guid, guid())
      |> Repo.insert!()
    end
  end

  describe "listar/3 — sin opciones (compat con MetaBcApi.listar/2)" do
    test "trae TODO sin límite cuando no se pasan opciones" do
      clientes = fixture_clientes(30)

      resultado = CatalogoGenerico.listar(MetaFixtureCliente, :sistema, %{})

      assert Enum.map(resultado, & &1.id) |> Enum.sort() == Enum.map(clientes, & &1.id) |> Enum.sort()
    end
  end

  describe "listar/3 — con limit/offset" do
    test "limit corta la cantidad de filas" do
      fixture_clientes(30)

      assert length(CatalogoGenerico.listar(MetaFixtureCliente, :sistema, %{}, limit: 25)) == 25
    end

    test "offset + limit da páginas sin solapar ni saltear filas (orden estable)" do
      clientes = fixture_clientes(30)
      ids_insertados = Enum.map(clientes, & &1.id) |> Enum.sort()

      pagina1 = CatalogoGenerico.listar(MetaFixtureCliente, :sistema, %{}, limit: 25, offset: 0) |> Enum.map(& &1.id)
      pagina2 = CatalogoGenerico.listar(MetaFixtureCliente, :sistema, %{}, limit: 25, offset: 25) |> Enum.map(& &1.id)

      assert length(pagina1) == 25
      assert length(pagina2) == 5

      # No hay intersección entre páginas -- si el orden no fuera estable
      # (sin order_by), Postgres podría repetir o saltear filas entre
      # llamadas con el mismo limit/offset.
      assert MapSet.disjoint?(MapSet.new(pagina1), MapSet.new(pagina2))
      assert Enum.sort(pagina1 ++ pagina2) == ids_insertados
    end
  end

  describe "contar/2" do
    test "cuenta sin verse afectado por limit/offset de otras llamadas" do
      fixture_clientes(30)

      total = CatalogoGenerico.contar(MetaFixtureCliente, :sistema)
      pagina = CatalogoGenerico.listar(MetaFixtureCliente, :sistema, %{}, limit: 25)

      assert total >= 30
      assert length(pagina) == 25
    end
  end

  # SPEC-SYS-0909202605 (tarea B1) -- acotado ÚNICAMENTE por ids, nunca
  # por filtros/búsqueda/parámetros de la vista.
  describe "agregar_seleccionados/5" do
    defp fixture_cliente(nombre, edad, venta) do
      %MetaFixtureCliente{}
      |> MetaFixtureCliente.changeset(%{meta_fixture_cliente_nombre: nombre, meta_fixture_cliente_edad: edad, meta_fixture_cliente_venta: Decimal.new(venta)})
      |> put_change(:insert_guid, guid())
      |> Repo.insert!()
    end

    test "SUMA/PROMEDIO/MÍNIMO/MÁXIMO/CONTEO se calculan SOLO sobre los ids elegidos" do
      a = fixture_cliente("Sel A #{unique()}", 10, "100.00")
      b = fixture_cliente("Sel B #{unique()}", 20, "200.00")
      _c_no_seleccionado = fixture_cliente("Sel C #{unique()}", 999, "999999.00")

      ids = [a.id, b.id]

      assert CatalogoGenerico.agregar_seleccionados(MetaFixtureCliente, :sistema, :meta_fixture_cliente_edad, :sum, ids) == 30
      assert CatalogoGenerico.agregar_seleccionados(MetaFixtureCliente, :sistema, :meta_fixture_cliente_edad, :avg, ids) |> Decimal.compare(Decimal.new(15)) == :eq
      assert CatalogoGenerico.agregar_seleccionados(MetaFixtureCliente, :sistema, :meta_fixture_cliente_edad, :min, ids) == 10
      assert CatalogoGenerico.agregar_seleccionados(MetaFixtureCliente, :sistema, :meta_fixture_cliente_edad, :max, ids) == 20
      assert CatalogoGenerico.agregar_seleccionados(MetaFixtureCliente, :sistema, :meta_fixture_cliente_edad, :count, ids) == 2
    end

    test "lista de ids vacía da nil, sin consultar nada" do
      assert CatalogoGenerico.agregar_seleccionados(MetaFixtureCliente, :sistema, :meta_fixture_cliente_edad, :sum, []) == nil
    end

    test "ignora un registro dado de baja aunque su id esté en la lista" do
      a = fixture_cliente("Sel Baja #{unique()}", 10, "100.00")
      a |> Ecto.Changeset.change(%{delete_guid: guid()}) |> Repo.update!()

      assert CatalogoGenerico.agregar_seleccionados(MetaFixtureCliente, :sistema, :meta_fixture_cliente_edad, :sum, [a.id]) == nil
    end
  end
end
