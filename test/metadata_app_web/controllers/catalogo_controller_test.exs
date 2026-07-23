defmodule MetadataAppWeb.BusinessProcessBuilder.CatalogoControllerTest do
  use MetadataAppWeb.ConnCase, async: true

  alias MetadataApp.Repo
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp fixture_clientes(cantidad) do
    for _ <- 1..cantidad do
      %MetaFixtureCliente{}
      |> MetaFixtureCliente.changeset(%{
        meta_fixture_cliente_nombre: "http paginacion #{unique()}",
        meta_fixture_cliente_edad: 30,
        meta_fixture_cliente_venta: Decimal.new("100.00")
      })
      |> Ecto.Changeset.put_change(:insert_guid, guid())
      |> Repo.insert!()
    end
  end

  describe "GET /api/:tabla — paginación" do
    test "sin parámetros: pagina 1, por_pagina 25 por default", %{conn: conn} do
      fixture_clientes(30)

      conn = get(conn, ~p"/api/meta_fixture_cliente")

      assert %{"data" => data, "paginacion" => paginacion} = json_response(conn, 200)
      assert length(data) == 25
      assert paginacion["pagina"] == 1
      assert paginacion["por_pagina"] == 25
      assert paginacion["total_filas"] == 30
      assert paginacion["total_paginas"] == 2
    end

    test "pagina 2 trae el resto", %{conn: conn} do
      fixture_clientes(30)

      conn = get(conn, ~p"/api/meta_fixture_cliente?pagina=2")

      assert %{"data" => data, "paginacion" => paginacion} = json_response(conn, 200)
      assert length(data) == 5
      assert paginacion["pagina"] == 2
    end

    test "por_pagina se clampea a un máximo (100)", %{conn: conn} do
      fixture_clientes(5)

      conn = get(conn, ~p"/api/meta_fixture_cliente?por_pagina=999999")

      assert %{"paginacion" => paginacion} = json_response(conn, 200)
      assert paginacion["por_pagina"] == 100
    end

    test "pagina inválida (0 o negativa) se clampea a 1", %{conn: conn} do
      fixture_clientes(5)

      conn = get(conn, ~p"/api/meta_fixture_cliente?pagina=-3")

      assert %{"paginacion" => paginacion} = json_response(conn, 200)
      assert paginacion["pagina"] == 1
    end

    test "parámetro no numérico cae al default en vez de romper", %{conn: conn} do
      fixture_clientes(5)

      conn = get(conn, ~p"/api/meta_fixture_cliente?por_pagina=abc")

      assert %{"paginacion" => paginacion} = json_response(conn, 200)
      assert paginacion["por_pagina"] == 25
    end

    test "dos páginas no repiten ni se saltean filas (orden estable)", %{conn: conn} do
      fixture_clientes(30)

      pagina1 = get(conn, ~p"/api/meta_fixture_cliente?pagina=1") |> json_response(200) |> Map.fetch!("data")
      pagina2 = get(conn, ~p"/api/meta_fixture_cliente?pagina=2") |> json_response(200) |> Map.fetch!("data")

      ids1 = MapSet.new(pagina1, & &1["id"])
      ids2 = MapSet.new(pagina2, & &1["id"])

      assert MapSet.disjoint?(ids1, ids2)
      assert MapSet.size(ids1) + MapSet.size(ids2) == 30
    end
  end

  describe "GET /api/:tabla — sin registros" do
    test "total_paginas es 1 (no 0) para no romper la UI de paginación", %{conn: conn} do
      conn = get(conn, ~p"/api/meta_fixture_equipo")

      assert %{"data" => [], "paginacion" => paginacion} = json_response(conn, 200)
      assert paginacion["total_filas"] == 0
      assert paginacion["total_paginas"] == 1
    end
  end
end
