defmodule MetadataAppWeb.Sysadmin.BcMotorLiveTotalRenglonesTest do
  @moduledoc """
  SPEC-SYS-1109202601 R50: columna "Total en renglones" en la tabla de
  Campos del Tab Configuración — solo para campos numéricos, Suma por
  default, se guarda al cambiarla.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Detail

  setup %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa total renglones #{System.unique_integer()}"}) |> Repo.insert()
    {:ok, _} = %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()
    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
    %{conn: conn, header: MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")}
  end

  defp props(header, campo),
    do: Repo.get_by!(Detail, meta_schema_header_id: header.id, schema_context_field: campo).schema_context_properties

  test "solo los campos numéricos tienen el selector, en Suma por default", %{conn: conn, header: header} do
    {:ok, view, _} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/motor")

    assert has_element?(view, "#total-renglones-meta_fixture_cliente_venta option[value=suma][selected]")
    refute has_element?(view, "#total-renglones-meta_fixture_cliente_nombre")
  end

  test "cambiarlo lo guarda en el campo", %{conn: conn, header: header} do
    {:ok, view, _} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/motor")

    view
    |> element("#total-renglones-meta_fixture_cliente_venta")
    |> render_change(%{"campo" => "meta_fixture_cliente_venta", "total_renglones" => "ninguno"})

    assert props(header, "meta_fixture_cliente_venta")["total_renglones"] == "ninguno"
    assert has_element?(view, "#total-renglones-meta_fixture_cliente_venta option[value=ninguno][selected]")
  end
end
