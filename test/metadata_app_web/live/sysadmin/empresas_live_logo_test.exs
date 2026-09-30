defmodule MetadataAppWeb.Sysadmin.EmpresasLiveLogoTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.{Empresa, EmpresaLogo}
  alias MetadataApp.Repo

  defp png(ancho, alto) do
    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", ancho::32, alto::32, 8, 6, 0, 0, 0,
      0::32>>
  end

  setup %{conn: conn} do
    usuario = usuario_fixture()

    # La empresa activa es otra: así guardar/quitar no re-monta la pantalla
    # y se puede seguir inspeccionando el modal.
    {:ok, activa} =
      Autenticacion.crear_empresa_para_usuario("Activa #{System.unique_integer()}", usuario.id)

    {:ok, empresa} =
      Autenticacion.crear_empresa_para_usuario("Cliente #{System.unique_integer()}", usuario.id)

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, activa.id)
    %{conn: conn, empresa: empresa, activa: activa}
  end

  defp abrir_editar(conn, empresa) do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/empresas")
    view |> element("#editar-empresa-#{empresa.id}") |> render_click()
    view
  end

  defp subir(view, nombre, contenido, tipo) do
    archivo =
      file_input(view, "#logo-empresa-form", :logo, [
        %{name: nombre, content: contenido, type: tipo}
      ])

    render_upload(archivo, nombre)
    archivo
  end

  test "el modal muestra la recomendación y ningún logo todavía", %{conn: conn, empresa: empresa} do
    view = abrir_editar(conn, empresa)

    assert has_element?(view, "#logo-empresa-recomendacion")
    refute has_element?(view, "#logo-empresa-actual")
    refute has_element?(view, "#logo-empresa-quitar")
  end

  test "subir muestra la vista previa y guardar persiste el logo", %{conn: conn, empresa: empresa} do
    view = abrir_editar(conn, empresa)
    subir(view, "logo.png", png(320, 64), "image/png")

    assert has_element?(view, "#logo-empresa-vista-previa img[src^=\"data:image/png;base64,\"]")
    refute has_element?(view, "#logo-empresa-aviso-proporcion")
    assert Repo.get!(Empresa, empresa.id).logo_version == nil

    view |> element("#logo-empresa-form") |> render_submit()

    empresa = Repo.get!(Empresa, empresa.id)
    assert empresa.logo_version
    assert Repo.get_by(EmpresaLogo, empresa_id: empresa.id)
    assert has_element?(view, "#logo-empresa-actual")
    assert has_element?(view, "#logo-empresa-#{empresa.id}")
  end

  test "una imagen cuadrada avisa, pero se puede guardar", %{conn: conn, empresa: empresa} do
    view = abrir_editar(conn, empresa)
    subir(view, "cuadrado.png", png(64, 64), "image/png")

    assert has_element?(view, "#logo-empresa-aviso-proporcion")

    view |> element("#logo-empresa-form") |> render_submit()
    assert Repo.get!(Empresa, empresa.id).logo_version
  end

  test "un SVG renombrado a .png se rechaza sin vista previa", %{conn: conn, empresa: empresa} do
    view = abrir_editar(conn, empresa)
    subir(view, "falso.png", ~s(<svg xmlns="http://www.w3.org/2000/svg"/>), "image/png")

    assert has_element?(view, ".logo-empresa-error", "Formato no permitido")
    refute has_element?(view, "#logo-empresa-vista-previa")
    refute has_element?(view, "#logo-empresa-guardar")
  end

  test "un archivo de más de 200 KB se rechaza antes de subirlo", %{conn: conn, empresa: empresa} do
    view = abrir_editar(conn, empresa)

    archivo =
      file_input(view, "#logo-empresa-form", :logo, [
        %{
          name: "grande.png",
          content: png(320, 64) <> :binary.copy(<<0>>, 200_001),
          type: "image/png"
        }
      ])

    assert {:error, [[_ref, :too_large]]} = render_upload(archivo, "grande.png")
    assert has_element?(view, ".logo-empresa-error", "200 KB")
  end

  test "descartar quita la vista previa sin guardar", %{conn: conn, empresa: empresa} do
    view = abrir_editar(conn, empresa)
    subir(view, "logo.png", png(320, 64), "image/png")

    view |> element("#logo-empresa-descartar") |> render_click()

    refute has_element?(view, "#logo-empresa-vista-previa")
    assert Repo.get!(Empresa, empresa.id).logo_version == nil
  end

  test "quitar borra el logo", %{conn: conn, empresa: empresa} do
    {:ok, _} = Autenticacion.guardar_logo_empresa(empresa, png(320, 64))
    view = abrir_editar(conn, empresa)

    view |> element("#logo-empresa-quitar") |> render_click()

    assert Repo.get!(Empresa, empresa.id).logo_version == nil
    refute Repo.get_by(EmpresaLogo, empresa_id: empresa.id)
    refute has_element?(view, "#logo-empresa-actual")
  end

  test "guardar el logo de la empresa activa re-monta la pantalla", %{conn: conn, activa: activa} do
    view = abrir_editar(conn, activa)
    subir(view, "logo.png", png(320, 64), "image/png")

    assert {:error, {:live_redirect, %{to: "/sysadmin/empresas"}}} =
             view |> element("#logo-empresa-form") |> render_submit()
  end
end
