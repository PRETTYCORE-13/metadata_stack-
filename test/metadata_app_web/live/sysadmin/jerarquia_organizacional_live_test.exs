defmodule MetadataAppWeb.Sysadmin.JerarquiaOrganizacionalLiveTest do
  @moduledoc """
  Fase 0 del modelo de Alcance de Datos (2026-08-11) — CRUD real, vía UI,
  de la jerarquía Empresa -> Branch -> {SalesUnit, InventoryLocation}.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion

  setup %{conn: conn} do
    usuario = usuario_fixture()
    # crear_empresa_para_usuario/2 ya deja al creador como "administrador"
    # de esa empresa -- no hace falta asignar_rol/3 aparte.
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa jerarquia UI #{System.unique_integer()}", usuario.id)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn, empresa: empresa}
  end

  test "crea una sucursal, y desde ahí una unidad de ventas y una ubicación de inventario", %{conn: conn, empresa: empresa} do
    {:ok, view, _html} = live(conn, "/sysadmin/jerarquia")

    view |> element("button", empresa.nombre) |> render_click()
    view |> element("button", "+ Nueva") |> render_click()

    html =
      view
      |> form("form[phx-submit=guardar_branch]", %{"branch" => %{"branch_name" => "Toluca"}})
      |> render_submit()

    assert html =~ "Sucursal creada"
    assert html =~ "Toluca"

    view |> element("button", "Toluca") |> render_click()

    view |> element("button[phx-click=nueva_sales_unit]") |> render_click()

    html =
      view
      |> form("form[phx-submit=guardar_sales_unit]", %{
        "sales_unit" => %{"sales_unit_name" => "Preventa 1", "sales_unit_type" => "preventa"}
      })
      |> render_submit()

    assert html =~ "Unidad de ventas creada"
    assert html =~ "Preventa 1"

    view |> element("button[phx-click=nueva_inventory_location]") |> render_click()

    html =
      view
      |> form("form[phx-submit=guardar_inventory_location]", %{
        "inventory_location" => %{"inventory_name" => "Producto terminado", "inventory_type" => "almacen"}
      })
      |> render_submit()

    assert html =~ "Ubicación de inventario creada"
    assert html =~ "Producto terminado"

    # Confirma la denormalización de punta a punta -- las hojas creadas
    # desde la UI también quedan con empresa_id sin ningún join.
    [branch] = Autenticacion.listar_branches(empresa.id)
    [sales_unit] = Autenticacion.listar_sales_units(branch.id)
    [inventory_location] = Autenticacion.listar_inventory_locations(branch.id)

    assert sales_unit.empresa_id == empresa.id
    assert inventory_location.empresa_id == empresa.id
  end
end
