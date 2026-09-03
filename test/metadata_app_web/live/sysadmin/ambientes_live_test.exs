defmodule MetadataAppWeb.Sysadmin.AmbientesLiveTest do
  @moduledoc """
  Pantalla de "Ambientes de Deploy" (UI/ambientes-deploy, 2026-08-16) --
  mismo patrón maestro-detalle que CredencialesLive. Cubre el gate RBAC
  (sysadmin_ambientes/leer) y el flujo completo crear/editar/eliminar,
  incluido que la contraseña nunca vuelve a mostrarse en el form.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion
  alias MetadataApp.Ambientes

  setup %{conn: conn} do
    admin = usuario_fixture()
    # crear_empresa_para_usuario/2 deja al creador como "administrador" --
    # bypasea el gate sysadmin_ambientes/leer (Permissions.administrador?/2).
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa ambientes #{System.unique_integer()}", admin.id)

    conn =
      conn
      |> log_in_usuario(admin)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn}
  end

  test "un usuario sin sysadmin_ambientes/leer no puede entrar", %{conn: _conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa sin acceso #{System.unique_integer()}", usuario_fixture().id)
    Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)

    conn =
      build_conn()
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/sysadmin/ambientes")
  end

  test "crea un ambiente nuevo con contraseña", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/ambientes")

    view |> element("button", "+ Nuevo ambiente") |> render_click()

    html =
      view
      |> form("form[phx-submit=guardar_ambiente]", %{
        "ambiente" => %{
          "nombre" => "staging",
          "host" => "10.0.0.5",
          "ssh_usuario" => "deploy",
          "ssh_password_nuevo" => "secreto123",
          "imagen_docker" => "ghcr.io/prettycore-13/metadata_stack:latest"
        }
      })
      |> render_submit()

    assert html =~ "staging"
    ambiente = Ambientes.obtener_ambiente_por_nombre("staging")
    assert ambiente.host == "10.0.0.5"
    assert ambiente.ssh_password == "secreto123"
  end

  test "editar sin tocar la contraseña la conserva, y el form nunca la precarga", %{conn: conn} do
    {:ok, ambiente} =
      Ambientes.crear_ambiente(%{
        "nombre" => "edit-test",
        "host" => "10.0.0.6",
        "ssh_usuario" => "deploy",
        "ssh_password_nuevo" => "no-cambiar"
      })

    {:ok, view, _html} = live(conn, ~p"/sysadmin/ambientes")
    html = view |> element("button", "edit-test") |> render_click()

    # El input de contraseña siempre sale vacío -- nunca precargado con el
    # valor descifrado, mismo criterio que api_key_nuevo en CredencialesLive.
    refute html =~ "no-cambiar"

    view
    |> form("form[phx-submit=guardar_ambiente]", %{"ambiente" => %{"host" => "10.0.0.7"}})
    |> render_submit()

    recargado = Ambientes.obtener_ambiente!(ambiente.id)
    assert recargado.host == "10.0.0.7"
    assert recargado.ssh_password == "no-cambiar"
  end

  test "elimina un ambiente", %{conn: conn} do
    {:ok, ambiente} =
      Ambientes.crear_ambiente(%{
        "nombre" => "borrar-test",
        "host" => "10.0.0.8",
        "ssh_usuario" => "deploy",
        "ssh_password_nuevo" => "x"
      })

    {:ok, view, _html} = live(conn, ~p"/sysadmin/ambientes")
    view |> element("button", "borrar-test") |> render_click()
    view |> element("button", "Eliminar") |> render_click()

    assert Ambientes.obtener_ambiente_por_nombre("borrar-test") == nil
    assert_raise Ecto.NoResultsError, fn -> Ambientes.obtener_ambiente!(ambiente.id) end
  end
end
