defmodule MetadataAppWeb.Sysadmin.PurgarLiveTest do
  @moduledoc """
  Pantalla "Purgar" (SPEC-ARQ-3009202601, Grupo A): gate RBAC
  (`sysadmin_purgar`/`leer`), las dos pestañas y el switch de la capacidad
  en la pestaña Sysadmin de usuarios.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.{Autenticacion, Permissions, Repo}
  alias MetadataApp.Autenticacion.{Rol, Scope}

  setup %{conn: conn} do
    admin = usuario_fixture()

    {:ok, empresa} =
      Autenticacion.crear_empresa_para_usuario(
        "Empresa purgar #{System.unique_integer()}",
        admin.id
      )

    conn =
      conn
      |> log_in_usuario(admin)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn, empresa: empresa}
  end

  defp conn_de(usuario, empresa) do
    build_conn()
    |> log_in_usuario(usuario)
    |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
  end

  test "un usuario sin sysadmin_purgar/leer no puede entrar", %{empresa: empresa} do
    usuario = usuario_fixture()
    Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn_de(usuario, empresa), ~p"/sysadmin/purgar")
  end

  test "con el rol acceso_sysadmin_purgar entra aunque no sea administrador", %{empresa: empresa} do
    usuario = usuario_fixture()
    Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)
    rol = Repo.get_by!(Rol, nombre: "acceso_sysadmin_purgar", es_sistema: true)
    Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

    {:ok, view, _html} = live(conn_de(usuario, empresa), ~p"/sysadmin/purgar")

    assert has_element?(view, "#purgar-artefactos")
  end

  test "el rol se siembra como tipo sysadmin" do
    assert %Rol{tipo: :sysadmin} =
             Repo.get_by!(Rol, nombre: "acceso_sysadmin_purgar", es_sistema: true)
  end

  test "muestra las dos pestañas y arranca en Artefactos", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/purgar")

    assert has_element?(view, "#tab-artefactos[aria-current=page]")
    assert has_element?(view, "#tab-bitacora")
    assert has_element?(view, "#purgar-artefactos")
    refute has_element?(view, "#purgar-bitacora")
  end

  test "cambia a la pestaña Bitácora", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/purgar")

    view |> element("#tab-bitacora") |> render_click()

    assert_patched(view, ~p"/sysadmin/purgar?pestana=bitacora")
    assert has_element?(view, "#purgar-bitacora")
    refute has_element?(view, "#purgar-artefactos")
  end

  test "una pestaña desconocida en la URL cae en Artefactos", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/purgar?pestana=otra")

    assert has_element?(view, "#purgar-artefactos")
  end

  test "el switch de la pestaña Sysadmin concede la capacidad", %{conn: conn, empresa: empresa} do
    objetivo = usuario_fixture()
    Autenticacion.agregar_usuario_a_empresa(objetivo.email, empresa.id)
    scope = %Scope{usuario: objetivo, empresa_activa: empresa}

    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")

    view
    |> element(~s(button[phx-click=seleccionar_usuario][phx-value-id="#{objetivo.id}"]))
    |> render_click()

    refute Permissions.can?(scope, "leer", "sysadmin_purgar")

    view
    |> element(
      ~s(button[phx-click=toggle_capacidad_sysadmin][phx-value-recurso="sysadmin_purgar"])
    )
    |> render_click()

    assert Permissions.can?(scope, "leer", "sysadmin_purgar")
  end
end
