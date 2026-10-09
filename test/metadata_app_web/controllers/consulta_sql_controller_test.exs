defmodule MetadataAppWeb.BusinessProcessBuilder.ConsultaSqlControllerTest do
  @moduledoc "SPEC-SYS-2509202601 Grupo F: GET /api/:tabla y listado de una SQL View."
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.PermisosApiFixtures

  alias MetadataApp.{Repo, ConsultasSql}

  setup %{conn: conn} do
    empresa = empresa_fixture!()
    %{conn: conn, empresa: empresa}
  end

  defp sql_view(sql, uso \\ "consulta") do
    {:ok, {header, _}} =
      ConsultasSql.crear(%{"etiqueta" => "Vista API", "nav" => "/vista_api_#{System.unique_integer([:positive])}", "uso" => uso})

    {:ok, _} = ConsultasSql.guardar_sql(header.schema_context_name, sql)
    header
  end

  test "registra su permiso leer al crearse" do
    header = sql_view("SELECT 1 AS id, 'x' AS descripcion")
    assert MetadataApp.Permissions.permiso_existe?(header.schema_context_name, "leer")
  end

  test "GET trae meta_campos, data y paginación, en el orden del SQL", %{conn: conn, empresa: empresa} do
    header = sql_view("SELECT g AS id, 'fila ' || g AS descripcion FROM generate_series(1, 30) g ORDER BY g")
    conn = conn_autenticado(conn, usuario_administrador!(empresa), empresa)

    conn = get(conn, ~p"/api/#{header.schema_context_name}?pagina=2&por_pagina=10")

    assert %{"meta_campos" => [%{"clave" => "id", "tipo" => "integer"}, %{"clave" => "descripcion"}], "data" => data, "paginacion" => paginacion} =
             json_response(conn, 200)

    assert length(data) == 10
    assert hd(data) == %{"id" => 11, "descripcion" => "fila 11"}
    assert paginacion == %{"pagina" => 2, "por_pagina" => 10, "total_filas" => 30, "total_paginas" => 3}
  end

  test "sin el permiso leer, la API lo rechaza", %{conn: conn, empresa: empresa} do
    header = sql_view("SELECT 1 AS id, 'x' AS descripcion")
    conn = conn_autenticado(conn, usuario_sin_permiso!(empresa), empresa)

    conn = get(conn, ~p"/api/#{header.schema_context_name}")
    assert conn.status in [401, 403]
  end

  test "alcance: un usuario solo ve las filas de sus sucursales (y las sin sucursal)", %{conn: conn, empresa: empresa} do
    {:ok, branch} = MetadataApp.Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Sucursal alcance"})

    header =
      sql_view("SELECT * FROM (VALUES (1, #{branch.id}, 'a'), (2, -5, 'b'), (3, NULL, 'c')) AS t(id, branch_id, descripcion)")

    usuario = usuario_con_permiso!(empresa, header.schema_context_name, "leer")
    MetadataApp.Autenticacion.asignar_branch(usuario.id, branch.id)

    conn = get(conn_autenticado(conn, usuario, empresa), ~p"/api/#{header.schema_context_name}")

    assert %{"data" => data} = json_response(conn, 200)
    assert Enum.map(data, & &1["id"]) |> Enum.sort() == [1, 3]
  end

  test "visible en el menú: su ruta muestra el listado de solo lectura", %{conn: conn, empresa: empresa} do
    header = sql_view("SELECT 7 AS id, 'Ruta preventa' AS descripcion")
    header |> Ecto.Changeset.change(%{schema_visible: true}) |> Repo.update!()
    conn = conn_autenticado(conn, usuario_administrador!(empresa), empresa)

    {:ok, view, _html} = live(conn, header.schema_context_nav)
    assert has_element?(view, "#tabla-sql-view")
    assert render(view) =~ "Ruta preventa"
  end
end
