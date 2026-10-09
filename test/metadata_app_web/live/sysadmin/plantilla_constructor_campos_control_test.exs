defmodule MetadataAppWeb.Sysadmin.PlantillaConstructorCamposControlTest do
  @moduledoc """
  SPEC-SYS-1109202607 (R6a): los campos de control (Folio, Estado, TRN…)
  se pueden colocar en una plantilla custom. Todo nodo "campo" de la paleta
  trae un tipo_filtro, así que el selector los ofrece con cualquier filtro.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa campos control #{System.unique_integer()}"}) |> Repo.insert()

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

  test "un campo de Texto de la paleta ofrece Folio entre los campos de control", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/meta_fixture_cliente/plantilla")

    render_click(view, "nueva_plantilla", %{})
    render_click(view, "seleccionar_celda", %{"fila" => "0", "columna" => "0"})
    render_click(view, "grid_colocar_campo", %{"filtro" => "string"})

    assert has_element?(view, ~s(select[name="campo"] optgroup[label="Campos de control"] option[value="folio"]))
  end

  # R13-R14: la paleta en acordeón, solo Campos abierto al entrar. Que un
  # grupo abierto a mano siga así tras un patch (R15) es del navegador.
  test "la paleta muestra cada grupo como acordeón, solo Campos abierto", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/meta_fixture_cliente/plantilla")
    render_click(view, "nueva_plantilla", %{})

    for i <- 0..4 do
      assert has_element?(view, "details#paleta-grupo-#{i}:not([open])")
    end

    assert has_element?(view, "details#paleta-grupo-5[open] button[data-filtro=string]")
    assert has_element?(view, "details#paleta-grupo-0 button[data-tipo=seccion]")
  end
end
