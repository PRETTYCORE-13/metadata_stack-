defmodule MetadataAppWeb.InicioLiveTest do
  @moduledoc """
  Regresión real (2026-09-18, bug reportado en vivo en unstable): un
  usuario común sin NINGÚN permiso de Sysadmin y sin `super_admin` se
  quedaba sin el botón de engrane del sidebar (MenuLayout.sidebar/1) --
  y con eso, sin forma de llegar a "Configuración de cuenta" ni
  "Cerrar sesión" (SPEC-SYS-0909202601, R15: esos 2 ítems deben estar
  SIEMPRE, sin importar permisos). No se prueba acá vía InicioLive en
  particular por nada especial de esa pantalla -- es solo la página
  autenticada más simple para montar el layout compartido.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion

  test "un usuario sin ningún permiso de Sysadmin igual ve el engrane (Configuración de cuenta / Cerrar sesión)", %{conn: conn} do
    admin = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa engrane test #{System.unique_integer()}", admin.id)

    # Usuario COMÚN a propósito: se suma a la empresa sin que
    # agregar_usuario_a_empresa/2 le conceda ningún rol -- a diferencia
    # de admin (que sí es "administrador" vía crear_empresa_para_usuario/2
    # y bypasea Permissions.can?/3 para cualquier recurso, lo que
    # ocultaría el bug que este test busca reproducir).
    comun = usuario_fixture()
    Autenticacion.agregar_usuario_a_empresa(comun.email, empresa.id)

    conn =
      conn
      |> log_in_usuario(comun)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "pc-sidebar-config-btn"
    assert html =~ "Configuración de cuenta"
    assert html =~ "Cerrar sesión"
  end

  test "un usuario 'administrador' de su empresa también ve el engrane", %{conn: conn} do
    admin = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa engrane admin test #{System.unique_integer()}", admin.id)

    conn =
      conn
      |> log_in_usuario(admin)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "pc-sidebar-config-btn"
  end
end
