defmodule MetadataAppWeb.MenuDeveloperTest do
  @moduledoc """
  Submenú "Developer" del menú administrativo (SPEC-SYS-0909202601
  R13d): las opciones de plataforma viven dentro de su propio panel, no
  sueltas en el menú. Abrir/cerrar es JS del cliente; aquí solo se
  prueba qué se renderiza y dónde.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion
  alias MetadataApp.Repo

  @menu "#sidebar-config-dropdown"
  @submenu "#sidebar-config-dropdown-developer"

  defp conectar(conn, usuario) do
    {:ok, empresa} =
      Autenticacion.crear_empresa_para_usuario(
        "Empresa menú developer #{System.unique_integer()}",
        usuario.id
      )

    conn
    |> log_in_usuario(usuario)
    |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
  end

  test "un super_admin ve Developer y las opciones de plataforma solo dentro del submenú",
       %{conn: conn} do
    super_admin = usuario_fixture() |> Ecto.Changeset.change(super_admin: true) |> Repo.update!()

    {:ok, view, _html} = live(conectar(conn, super_admin), ~p"/")

    assert has_element?(view, "#{@menu} #sidebar-config-dropdown-developer-btn", "Developer")

    assert has_element?(
             view,
             ~s(#sidebar-config-dropdown-developer-btn[aria-controls="sidebar-config-dropdown-developer"][aria-expanded="false"])
           )

    for ruta <- ~w(/sysadmin/credenciales /sysadmin/ambientes /sysadmin/endpoints /sysadmin/propagacion) do
      assert has_element?(view, ~s(#{@submenu} a[href="#{ruta}"]))
      refute has_element?(view, ~s(#{@menu} > nav a[href="#{ruta}"]))
    end

    # Las opciones de negocio y de cuenta siguen en el menú principal.
    assert has_element?(view, ~s(#{@menu} a[href="/sysadmin/empresas"]))
    refute has_element?(view, ~s(#{@submenu} a[href="/sysadmin/empresas"]))
    assert has_element?(view, "#{@menu} > nav", "Cerrar sesión")
  end

  test "sin super_admin no hay botón Developer ni submenú, y el engrane sigue igual",
       %{conn: conn} do
    admin = usuario_fixture()

    {:ok, view, html} = live(conectar(conn, admin), ~p"/")

    refute has_element?(view, "#sidebar-config-dropdown-developer-btn")
    refute has_element?(view, @submenu)
    assert html =~ "pc-sidebar-config-btn"
    assert has_element?(view, "#{@menu} > nav", "Configuración de cuenta")
  end
end
