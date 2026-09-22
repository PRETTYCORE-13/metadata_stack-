defmodule MetadataAppWeb.SeguridadApiSysadminBcTest do
  @moduledoc """
  SPEC-SYS-2209202601 (R7-R8) -- autorización de las rutas de
  administración de catálogos (`meta_schema_header`, `meta_schema_estados`,
  `meta_schema_transiciones`, `catalogos/:tabla/{impacto,validar_motor,
  completitud,delete}`), todas gateadas por el permiso de plataforma fijo
  `sysadmin_bc` (mismo recurso que ya protege BC Motor/BC List en la web) —
  no por el nombre del catálogo puntual como el resto de la API. No
  exhaustivo sobre la lógica de negocio de cada controller (eso ya está
  cubierto en otros tests) -- solo confirma que la autorización corta
  ANTES de llegar a esa lógica.
  """

  use MetadataAppWeb.ConnCase, async: true

  import MetadataApp.PermisosApiFixtures

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  defp header_real!, do: MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")

  describe "sin sesión -> 401 en las 8 rutas" do
    test "meta_schema_header (index/show/create/update)", %{conn: conn} do
      header = header_real!()

      for resp <- [
            get(conn, ~p"/api/meta_schema_header"),
            get(conn, ~p"/api/meta_schema_header/#{header.id}"),
            post(conn, ~p"/api/meta_schema_header", %{}),
            put(conn, ~p"/api/meta_schema_header/#{header.id}", %{})
          ] do
        assert %{"errors" => %{"detail" => "no autenticado"}} = json_response(resp, 401)
      end
    end

    test "meta_schema_estados, meta_schema_transiciones (index/create)", %{conn: conn} do
      for resp <- [
            get(conn, ~p"/api/meta_schema_estados"),
            post(conn, ~p"/api/meta_schema_estados", %{}),
            get(conn, ~p"/api/meta_schema_transiciones"),
            post(conn, ~p"/api/meta_schema_transiciones", %{})
          ] do
        assert %{"errors" => %{"detail" => "no autenticado"}} = json_response(resp, 401)
      end
    end

    test "catalogos/:tabla (impacto/validar_motor/completitud/delete)", %{conn: conn} do
      for resp <- [
            get(conn, ~p"/api/catalogos/meta_fixture_cliente/impacto"),
            get(conn, ~p"/api/catalogos/meta_fixture_cliente/validar_motor"),
            get(conn, ~p"/api/catalogos/meta_fixture_cliente/completitud"),
            delete(conn, ~p"/api/catalogos/meta_fixture_cliente")
          ] do
        assert %{"errors" => %{"detail" => "no autenticado"}} = json_response(resp, 401)
      end
    end
  end

  describe "con sesión pero sin sysadmin_bc -> 403" do
    test "un permiso de OTRO catálogo (no sysadmin_bc) no alcanza", %{conn: conn} do
      empresa = empresa_fixture!()
      # tiene leer/crear/editar de un catálogo real -- confirma que estas rutas
      # NO se resuelven contra el nombre de ningún catálogo puntual, solo sysadmin_bc.
      usuario = usuario_con_permiso!(empresa, "meta_fixture_cliente", "editar")
      conn = conn_autenticado(conn, usuario, empresa)

      assert %{"errors" => %{"detail" => "sin permiso"}} =
               get(conn, ~p"/api/meta_schema_header") |> json_response(403)

      assert %{"errors" => %{"detail" => "sin permiso"}} =
               delete(conn, ~p"/api/catalogos/meta_fixture_cliente") |> json_response(403)
    end
  end

  describe "con sysadmin_bc, la autorización pasa (R7-R8)" do
    test "leer alcanza para las rutas de consulta", %{conn: conn} do
      header = header_real!()
      empresa = empresa_fixture!()
      usuario = usuario_con_permiso!(empresa, "sysadmin_bc", "leer")
      conn = conn_autenticado(conn, usuario, empresa)

      assert %{"data" => _} = get(conn, ~p"/api/meta_schema_header") |> json_response(200)
      assert %{"data" => _} = get(conn, ~p"/api/meta_schema_header/#{header.id}") |> json_response(200)
    end

    test "leer NO alcanza para escribir (crear/editar/borrar exigen sysadmin_bc/editar)", %{conn: conn} do
      empresa = empresa_fixture!()
      usuario = usuario_con_permiso!(empresa, "sysadmin_bc", "leer")
      conn = conn_autenticado(conn, usuario, empresa)

      assert %{"errors" => %{"detail" => "sin permiso"}} =
               post(conn, ~p"/api/meta_schema_header", %{}) |> json_response(403)

      assert %{"errors" => %{"detail" => "sin permiso"}} =
               delete(conn, ~p"/api/catalogos/meta_fixture_cliente") |> json_response(403)
    end

    test "administrador pasa sin necesitar el permiso concedido a ningún rol (R9)", %{conn: conn} do
      empresa = empresa_fixture!()
      usuario = usuario_administrador!(empresa)
      MetadataApp.Permissions.crear_permiso(%{recurso: "sysadmin_bc", accion: "leer"})
      conn = conn_autenticado(conn, usuario, empresa)

      assert %{"data" => _} = get(conn, ~p"/api/meta_schema_header") |> json_response(200)
    end
  end
end
