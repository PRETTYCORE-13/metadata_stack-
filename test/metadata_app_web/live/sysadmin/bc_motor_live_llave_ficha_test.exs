defmodule MetadataAppWeb.Sysadmin.BcMotorLiveLlaveFichaTest do
  @moduledoc """
  SPEC-SYS-1109202607 §6c (R17-R20): la llave de identificación de la Ficha
  se configura en el tab Formulario, ya no en Get Config, y se sigue
  guardando en el encabezado del catálogo.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  setup %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa llave #{System.unique_integer()}"}) |> Repo.insert()
    {:ok, _} = %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, Repo.get_by!(Rol, nombre: "administrador").id, empresa.id)

    %{conn: conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)}
  end

  test "la llave vive en el tab Formulario y se guarda en el encabezado", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/meta_fixture_cliente/motor")

    assert has_element?(view, "#motor-panel-postview #formulario-llave-ficha")
    refute has_element?(view, "#get-view-llave-ficha")
    refute view |> element("#formulario-llave-ficha summary") |> render() =~ "Ficha 360"

    render_click(view, "abrir_selector_llave_ficha", %{})
    render_click(view, "agregar_llave_ficha", %{"campo" => "meta_fixture_cliente_nombre"})

    assert MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente").campos_llave_ficha == ["meta_fixture_cliente_nombre"]
  end
end
