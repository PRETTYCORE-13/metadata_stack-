defmodule MetadataApp.BusinessProcessBuilder.CatalogoGenericoTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.MetaBusinessProcess.Catalogos.PtyClientes

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  # 30 clientes, insertados en orden -- suficiente para tener 2 páginas
  # completas de 25 y probar límite/offset de verdad.
  defp fixture_clientes(cantidad) do
    for _ <- 1..cantidad do
      %PtyClientes{}
      |> PtyClientes.changeset(%{
        pty_clientes_nombre: "paginacion #{unique()}",
        pty_clientes_edad: 30,
        pty_clientes_venta: Decimal.new("100.00")
      })
      |> put_change(:insert_guid, guid())
      |> Repo.insert!()
    end
  end

  describe "listar/3 — sin opciones (compat con MetaBcCliente.listar/2)" do
    test "trae TODO sin límite cuando no se pasan opciones" do
      clientes = fixture_clientes(30)

      resultado = CatalogoGenerico.listar(PtyClientes, %{})

      assert Enum.map(resultado, & &1.id) |> Enum.sort() == Enum.map(clientes, & &1.id) |> Enum.sort()
    end
  end

  describe "listar/3 — con limit/offset" do
    test "limit corta la cantidad de filas" do
      fixture_clientes(30)

      assert length(CatalogoGenerico.listar(PtyClientes, %{}, limit: 25)) == 25
    end

    test "offset + limit da páginas sin solapar ni saltear filas (orden estable)" do
      clientes = fixture_clientes(30)
      ids_insertados = Enum.map(clientes, & &1.id) |> Enum.sort()

      pagina1 = CatalogoGenerico.listar(PtyClientes, %{}, limit: 25, offset: 0) |> Enum.map(& &1.id)
      pagina2 = CatalogoGenerico.listar(PtyClientes, %{}, limit: 25, offset: 25) |> Enum.map(& &1.id)

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

      total = CatalogoGenerico.contar(PtyClientes)
      pagina = CatalogoGenerico.listar(PtyClientes, %{}, limit: 25)

      assert total >= 30
      assert length(pagina) == 25
    end
  end
end
