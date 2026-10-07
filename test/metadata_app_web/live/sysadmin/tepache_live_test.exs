defmodule MetadataAppWeb.Sysadmin.TepacheLiveTest do
  @moduledoc """
  Barra de progreso del export (SPEC-SYS-0710202601 R20). Solo cubre el
  rechazo de R9: el camino feliz publicaría un release real en GitHub.
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
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa tepache test #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    s = System.unique_integer([:positive])
    maestro = "pty_tep_lv#{s}"
    detalle = "#{maestro}_det"

    {:ok, {h_maestro, _}} = MetaSchemaContext.crear_header_con_detalles(attrs(maestro))

    {:ok, _} =
      MetaSchemaContext.crear_header_con_detalles(Map.put(attrs(detalle), "schema_encabezado_id", h_maestro.id))

    %{conn: conn, maestro: maestro, detalle: detalle}
  end

  defp attrs(nombre) do
    %{
      "schema_context_name" => nombre,
      "schema_context_label" => nombre,
      "schema_context_nav" => "/#{nombre}",
      "schema_visible" => true,
      "schema_context_type" => 1,
      "detalles" => []
    }
  end

  test "al exportar sin una dependencia, la barra se va y queda el error de R9", c do
    {:ok, view, _html} = live(c.conn, ~p"/sysadmin/tepache")

    refute has_element?(view, "#tepache-progreso")

    render_click(view, "agregar_seleccionado", %{"recurso" => c.maestro})
    view |> form("#tepache-exportar-form", %{"descripcion" => ""}) |> render_submit()

    # El default (100ms) no alcanza con la suite completa en paralelo.
    render_async(view, 5_000)

    refute has_element?(view, "#tepache-progreso")
    assert has_element?(view, "#tepache-export-error", c.detalle)
    refute has_element?(view, "#tepache-exportar-btn[disabled]")
  end

  # R22: el import corre en segundo plano; un tag inexistente termina en
  # la caja roja, sin la barra, y la pantalla sigue viva.
  test "importar un tag inexistente muestra el error, sin barra, y la pantalla sigue respondiendo", c do
    {:ok, view, _html} = live(c.conn, ~p"/sysadmin/tepache")

    refute has_element?(view, "#tepache-progreso-import")

    view
    |> form("#tepache-importar-form", %{"tag" => "TEPACHE-NO-EXISTE-#{System.unique_integer([:positive])}"})
    |> render_submit()

    # Consulta GitHub de verdad (gh release download): más margen que el export.
    render_async(view, 30_000)

    refute has_element?(view, "#tepache-progreso-import")
    assert has_element?(view, "#tepache-import-error")
    refute has_element?(view, "#tepache-importar-btn[disabled]")
    assert render(view) =~ "Importar"
  end

  test "importar sin tag muestra el error sin lanzar nada en segundo plano", c do
    {:ok, view, _html} = live(c.conn, ~p"/sysadmin/tepache")

    view |> form("#tepache-importar-form", %{"tag" => "  "}) |> render_submit()

    assert has_element?(view, "#tepache-import-error")
    refute has_element?(view, "#tepache-progreso-import")
  end
end
