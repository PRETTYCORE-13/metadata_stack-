defmodule MetadataAppWeb.Sysadmin.BcMotorLiveOrdenResultadosTest do
  @moduledoc """
  Cubre la sección "Orden de resultados" del Get Config del BC Motor
  (2026-09-02, a pedido explícito -- mismo patrón que
  consulta_editor_live.ex, ver panel_orden_resultados/1 en
  bc_motor_live.ex): agregar/cambiar dirección/mover/quitar columnas de
  orden, persistido en Header.orden_resultados y aplicado de verdad por
  CatalogoGenerico.listar/5 (ver catalogo_generico_test.exs para esa
  parte -- acá cubre la UI/los handlers).
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa motor orden #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn}
  end

  test "agregar, cambiar dirección, mover y quitar columnas de orden", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    {:ok, header} = MetaSchemaContext.actualizar_header(header, %{"orden_resultados" => []})

    {:ok, view, html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/motor")
    assert html =~ "Orden de resultados"
    assert html =~ "Sin orden configurado"

    render_click(view, "abrir_selector_orden_resultados", %{})
    html = render_click(view, "agregar_orden_resultados", %{"campo" => "meta_fixture_cliente_nombre"})
    assert html =~ "Nombre"
    assert html =~ "Ascendente"

    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    assert header.orden_resultados == [%{"campo" => "meta_fixture_cliente_nombre", "direccion" => "asc"}]

    render_click(view, "abrir_selector_orden_resultados", %{})
    render_click(view, "agregar_orden_resultados", %{"campo" => "meta_fixture_cliente_edad"})

    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    assert header.orden_resultados == [
             %{"campo" => "meta_fixture_cliente_nombre", "direccion" => "asc"},
             %{"campo" => "meta_fixture_cliente_edad", "direccion" => "asc"}
           ]

    html = render_click(view, "cambiar_direccion_orden_resultados", %{"indice" => "0"})
    assert html =~ "Descendente"

    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    assert Enum.at(header.orden_resultados, 0)["direccion"] == "desc"

    render_click(view, "mover_orden_resultados", %{"indice" => "0", "direccion" => "abajo"})

    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    assert Enum.map(header.orden_resultados, & &1["campo"]) == ["meta_fixture_cliente_edad", "meta_fixture_cliente_nombre"]

    render_click(view, "quitar_orden_resultados", %{"indice" => "0"})

    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    assert header.orden_resultados == [%{"campo" => "meta_fixture_cliente_nombre", "direccion" => "desc"}]

    {:ok, _} = MetaSchemaContext.actualizar_header(header, %{"orden_resultados" => []})
  end
end
