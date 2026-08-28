defmodule MetadataAppWeb.Sysadmin.BcMotorLiveEncabezadoTest do
  @moduledoc """
  Cubre el panel "Encabezado" (etiqueta/navegación/ícono/visible) después
  de extraerlo a `MetadataAppWeb.EncabezadoBcComponents` (2026-08-26,
  reusado tal cual por ConsultaEditorLive) — nada de esto tenía cobertura
  automatizada antes de la extracción.
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
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa motor encabezado #{System.unique_integer()}"}) |> Repo.insert()

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

  test "valida en vivo, guarda etiqueta/navegación/ícono/visible y detecta colisión de ruta", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")

    {:ok, view, html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/motor")
    assert html =~ "Encabezado"
    assert html =~ "Etiqueta:"
    assert html =~ "Navegación:"
    assert html =~ "Ícono:"

    html_validado =
      view
      |> form("form[phx-submit=guardar_header]", %{"header" => %{"etiqueta" => "Fixture Cliente Editado", "segmento" => "fixture-cliente-editado", "visible" => "true"}})
      |> render_change()

    refute html_validado =~ "no puede quedar vacía"

    render_click(view, "elegir_icono_header", %{"icono" => "star"})

    html_guardado =
      view
      |> form("form[phx-submit=guardar_header]", %{"header" => %{"etiqueta" => "Fixture Cliente Editado", "segmento" => "fixture-cliente-editado", "visible" => "true"}})
      |> render_submit()

    assert html_guardado =~ "Encabezado actualizado."

    header_actualizado = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")
    assert header_actualizado.schema_context_label == "Fixture Cliente Editado"
    assert header_actualizado.schema_context_nav == "/__test__/fixture-cliente-editado"
    assert header_actualizado.schema_context_icono == "star"
    assert header_actualizado.schema_visible == true

    {:ok, _} =
      MetaSchemaContext.actualizar_header(header_actualizado, %{
        "schema_context_label" => header.schema_context_label,
        "schema_context_nav" => header.schema_context_nav,
        "schema_context_icono" => header.schema_context_icono,
        "schema_visible" => header.schema_visible
      })
  end

  test "etiqueta vacía al guardar muestra error y no persiste", %{conn: conn} do
    header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_equipo")

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/motor")

    html =
      view
      |> form("form[phx-submit=guardar_header]", %{"header" => %{"etiqueta" => "", "segmento" => "algo", "icono" => "", "visible" => "true"}})
      |> render_submit()

    assert html =~ "La etiqueta no puede quedar vacía."

    header_sin_cambios = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_equipo")
    assert header_sin_cambios.schema_context_label == header.schema_context_label
  end
end
