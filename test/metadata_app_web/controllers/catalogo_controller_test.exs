defmodule MetadataAppWeb.BusinessProcessBuilder.CatalogoControllerTest do
  use MetadataAppWeb.ConnCase, async: true

  import MetadataApp.PermisosApiFixtures

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
    # SPEC-SYS-2209202601 -- GET ahora exige {recurso: "meta_fixture_cliente", accion: "leer"}.
    setup %{conn: conn} do
      empresa = empresa_fixture!()
      usuario = usuario_con_permiso!(empresa, "meta_fixture_cliente", "leer")
      %{conn: conn_autenticado(conn, usuario, empresa)}
    end

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
    setup %{conn: conn} do
      empresa = empresa_fixture!()
      usuario = usuario_con_permiso!(empresa, "meta_fixture_equipo", "leer")
      %{conn: conn_autenticado(conn, usuario, empresa)}
    end

    test "total_paginas es 1 (no 0) para no romper la UI de paginación", %{conn: conn} do
      conn = get(conn, ~p"/api/meta_fixture_equipo")

      assert %{"data" => [], "paginacion" => paginacion} = json_response(conn, 200)
      assert paginacion["total_filas"] == 0
      assert paginacion["total_paginas"] == 1
    end
  end

  describe "autorización (SPEC-SYS-2209202601, R1-R5, R9)" do
    test "sin sesión -> 401 en las 4 acciones, ninguna llega a tocar datos", %{conn: conn} do
      assert %{"errors" => %{"detail" => "no autenticado"}} = get(conn, ~p"/api/meta_fixture_cliente") |> json_response(401)
      assert %{"errors" => %{"detail" => "no autenticado"}} = post(conn, ~p"/api/meta_fixture_cliente", %{}) |> json_response(401)
      assert %{"errors" => %{"detail" => "no autenticado"}} = put(conn, ~p"/api/meta_fixture_cliente/1", %{}) |> json_response(401)
      assert %{"errors" => %{"detail" => "no autenticado"}} = delete(conn, ~p"/api/meta_fixture_cliente/1") |> json_response(401)
    end

    test "con sesión pero sin el permiso de la acción -> 403, no el genérico de cualquier permiso", %{conn: conn} do
      empresa = empresa_fixture!()
      # tiene "crear" pero no "leer" -- confirma que el chequeo es por acción, no "tiene algún permiso en este catálogo".
      usuario = usuario_con_permiso!(empresa, "meta_fixture_cliente", "crear")
      conn = conn_autenticado(conn, usuario, empresa)

      assert %{"errors" => %{"detail" => "sin permiso"}} = get(conn, ~p"/api/meta_fixture_cliente") |> json_response(403)
    end

    test "con el permiso correcto, la request pasa la autorización (llega al controller)", %{conn: conn} do
      empresa = empresa_fixture!()
      usuario = usuario_con_permiso!(empresa, "meta_fixture_cliente", "eliminar")
      conn = conn_autenticado(conn, usuario, empresa)

      # id inexistente -> Ecto.NoResultsError adentro del controller (no 401/403) confirma
      # que la autorización ya pasó y el request efectivamente llegó a CatalogoGenerico.obtener!/3.
      assert_raise Ecto.NoResultsError, fn -> delete(conn, ~p"/api/meta_fixture_cliente/999999999") end
    end

    test "administrador pasa sin necesitar el permiso concedido a ningún rol (R9)", %{conn: conn} do
      empresa = empresa_fixture!()
      usuario = usuario_administrador!(empresa)
      MetadataApp.Permissions.crear_permiso(%{recurso: "meta_fixture_cliente", accion: "leer"})
      conn = conn_autenticado(conn, usuario, empresa)

      assert %{"data" => []} = get(conn, ~p"/api/meta_fixture_cliente") |> json_response(200)
    end
  end
end
