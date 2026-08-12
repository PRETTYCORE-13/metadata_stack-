defmodule MetadataAppWeb.Sysadmin.UsuariosEmpresaLiveTest do
  @moduledoc """
  Fase 7 del modelo de Alcance de Datos (2026-08-11) — pestaña "Alcance"
  de UsuariosEmpresaLive: asignar/revocar branches, sales units e
  inventory locations a un usuario, vía clicks reales, y confirmar que
  queda reflejado en Autenticacion.alcance_de_usuario/2 (la fuente que
  UsuarioAuth.hidratar_alcance/2 usa para armar el Scope real).
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion

  setup %{conn: conn} do
    admin = usuario_fixture()
    # crear_empresa_para_usuario/2 ya deja al creador como "administrador"
    # de esa empresa -- satisface el gate rbac_admin/leer de esta pantalla.
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa alcance usuario UI #{System.unique_integer()}", admin.id)

    objetivo = usuario_fixture()
    Autenticacion.agregar_usuario_a_empresa(objetivo.email, empresa.id)

    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})

    {:ok, sales_unit} =
      Autenticacion.crear_sales_unit(%{empresa_id: empresa.id, branch_id: branch.id, sales_unit_name: "Preventa 1"})

    {:ok, inventory_location} =
      Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Producto terminado"})

    conn =
      conn
      |> log_in_usuario(admin)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{
      conn: conn,
      empresa: empresa,
      objetivo: objetivo,
      branch: branch,
      sales_unit: sales_unit,
      inventory_location: inventory_location
    }
  end

  test "asigna y revoca una sucursal en la pestaña Alcance", %{conn: conn, empresa: empresa, objetivo: objetivo, branch: branch} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")

    view |> element("button[phx-click=seleccionar_usuario][phx-value-id=\"#{objetivo.id}\"]") |> render_click()

    html = view |> element("button[phx-click=toggle_branch_alcance]") |> render_click()
    assert html =~ "✓ Asignado"
    assert Autenticacion.alcance_de_usuario(objetivo.id, empresa.id).branches_permitidos == [branch.id]

    html = view |> element("button[phx-click=toggle_branch_alcance]") |> render_click()
    assert html =~ "+ Asignar"
    assert Autenticacion.alcance_de_usuario(objetivo.id, empresa.id).branches_permitidos == []
  end

  test "asigna una sales unit y una inventory location de forma independiente de la sucursal", %{
    conn: conn,
    empresa: empresa,
    objetivo: objetivo,
    sales_unit: sales_unit,
    inventory_location: inventory_location
  } do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")

    view |> element("button[phx-click=seleccionar_usuario][phx-value-id=\"#{objetivo.id}\"]") |> render_click()

    view |> element("button[phx-click=toggle_sales_unit_alcance]") |> render_click()
    view |> element("button[phx-click=toggle_inventory_location_alcance]") |> render_click()

    alcance = Autenticacion.alcance_de_usuario(objetivo.id, empresa.id)
    assert alcance.sales_units_permitidas == [sales_unit.id]
    assert alcance.inventory_locations_permitidas == [inventory_location.id]
    # La sucursal en sí no se tocó -- son 3 asignaciones independientes.
    assert alcance.branches_permitidos == []
  end
end
