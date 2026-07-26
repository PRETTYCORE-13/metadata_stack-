defmodule MetadataAppWeb.Plugs.RequierePermisoTest do
  use MetadataAppWeb.ConnCase, async: true

  alias MetadataAppWeb.Plugs.RequierePermiso
  alias MetadataApp.{Permissions, Repo}
  alias MetadataApp.Autenticacion.{Empresa, Scope}

  import MetadataApp.AutenticacionFixtures

  defp empresa_fixture do
    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa #{System.unique_integer()}"}) |> Repo.insert()

    empresa
  end

  defp llamar(conn, scope, opts) do
    conn
    |> Plug.Conn.assign(:current_scope, scope)
    |> RequierePermiso.call(RequierePermiso.init(opts))
  end

  test "sin current_scope (no autenticado) -> 401 y corta", %{conn: conn} do
    conn = llamar(conn, nil, recurso: "algo", accion: "leer")

    assert conn.halted
    assert conn.status == 401
  end

  test "autenticado pero sin el permiso -> 403 y corta", %{conn: conn} do
    usuario = usuario_fixture()
    empresa = empresa_fixture()
    scope = %Scope{usuario: usuario, empresa_activa: empresa}

    conn = llamar(conn, scope, recurso: "algo", accion: "leer")

    assert conn.halted
    assert conn.status == 403
  end

  test "autenticado con el permiso -> sigue sin cortar", %{conn: conn} do
    usuario = usuario_fixture()
    empresa = empresa_fixture()
    {:ok, permiso} = Permissions.crear_permiso(%{recurso: "algo", accion: "leer"})
    {:ok, rol} = Permissions.crear_rol(%{empresa_id: empresa.id, nombre: "Rol plug test"})
    {:ok, _} = Permissions.asignar_permiso_a_rol(rol.id, permiso.id)
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)
    scope = %Scope{usuario: usuario, empresa_activa: empresa}

    conn = llamar(conn, scope, recurso: "algo", accion: "leer")

    refute conn.halted
  end

  test "toma el recurso de conn.params[\"tabla\"] cuando no se pasa uno fijo", %{conn: conn} do
    usuario = usuario_fixture()
    empresa = empresa_fixture()
    {:ok, permiso} = Permissions.crear_permiso(%{recurso: "pty_dinamico", accion: "leer"})
    {:ok, rol} = Permissions.crear_rol(%{empresa_id: empresa.id, nombre: "Rol plug dinamico"})
    {:ok, _} = Permissions.asignar_permiso_a_rol(rol.id, permiso.id)
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)
    scope = %Scope{usuario: usuario, empresa_activa: empresa}

    conn =
      conn
      |> Map.put(:params, %{"tabla" => "pty_dinamico"})
      |> llamar(scope, accion: "leer")

    refute conn.halted
  end
end
