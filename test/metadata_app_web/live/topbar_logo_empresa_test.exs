defmodule MetadataAppWeb.TopbarLogoEmpresaTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", 320::32, 64::32, 8, 6, 0, 0, 0,
         0::32>>

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      Autenticacion.crear_empresa_para_usuario(
        "Empresa topbar #{System.unique_integer()}",
        usuario.id
      )

    conn =
      conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn, empresa: empresa}
  end

  test "sin logo, la top bar no muestra la caja del logo", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/empresas")

    refute has_element?(view, "#topbar-logo-empresa")
  end

  test "con logo, lo muestra con la URL de su versión vigente", %{conn: conn, empresa: empresa} do
    {:ok, empresa} = Autenticacion.guardar_logo_empresa(empresa, @png)

    {:ok, view, _html} = live(conn, ~p"/sysadmin/empresas")

    assert has_element?(
             view,
             ~s(#topbar-logo-empresa img[src="/empresas/#{empresa.id}/logo/#{empresa.logo_version}"])
           )
  end
end
