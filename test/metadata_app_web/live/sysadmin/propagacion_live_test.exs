defmodule MetadataAppWeb.Sysadmin.PropagacionLiveTest do
  @moduledoc """
  Pantalla "Propagación" (SPEC-SYS-1809202603, Grupo E) -- solo lectura
  en este incremento. Cubre el gate RBAC (sysadmin_propagacion/leer) y el
  estado sin ambientes registrados -- NO crea ningún `Ambiente` en estos
  tests a propósito: con uno registrado, el mount dispara una carga
  async real (git + gh + SSH) -- sin mock en este proyecto para eso
  (mismo criterio que el resto de `MotorAlta`), se verifica real por
  separado, no acá.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion

  setup %{conn: conn} do
    admin = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa propagación #{System.unique_integer()}", admin.id)

    conn =
      conn
      |> log_in_usuario(admin)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn}
  end

  test "un usuario sin sysadmin_propagacion/leer no puede entrar" do
    usuario = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa sin acceso #{System.unique_integer()}", usuario_fixture().id)
    Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)

    conn =
      build_conn()
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/sysadmin/propagacion")
  end

  test "un administrador entra y ve el selector de ambiente vacío (ninguno registrado)", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sysadmin/propagacion")

    assert html =~ "Propagación"
    assert html =~ "Elige un ambiente"
  end

  test "toggle_picker no crashea sin commits cargados (ningún ambiente elegido todavía)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/propagacion")

    html = render_click(view, "toggle_picker", %{"hash" => "abc123"})
    assert html =~ "Propagación"
  end
end
