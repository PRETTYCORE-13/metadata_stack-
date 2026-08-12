defmodule MetadataAppWeb.Sysadmin.UsuariosEmpresaLiveTest do
  @moduledoc """
  Pestaña "Alcance" de UsuariosEmpresaLive (Fase 7 del modelo de Alcance
  de Datos, 2026-08-11; rediseñada 2026-08-12 a pedido explícito -- 4
  secciones verticales en orden fijo, Empresa/Sucursales/Almacén/Unidades
  de venta, cada una "lista de lo asignado + Quitar" seguida de
  "<select> de lo disponible + Agregar" -- ver .seccion_alcance/1. La
  pestaña "Empresas" separada de antes desapareció, ese contenido ahora
  vive como la primera sección de acá.
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

  defp seleccionar(view, usuario) do
    view |> element("button[phx-click=seleccionar_usuario][phx-value-id=\"#{usuario.id}\"]") |> render_click()
  end

  test "agrega y quita una sucursal en la sección Sucursales", %{conn: conn, empresa: empresa, objetivo: objetivo, branch: branch} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
    seleccionar(view, objetivo)

    html =
      view
      |> form("form[phx-submit=agregar_branch_a_usuario]", %{"id" => to_string(branch.id)})
      |> render_submit()

    assert html =~ branch.branch_name
    assert Autenticacion.alcance_de_usuario(objetivo.id, empresa.id).branches_permitidos == [branch.id]

    html = view |> element("button[phx-click=quitar_branch_de_usuario]") |> render_click()
    refute html =~ "phx-click=\"quitar_branch_de_usuario\""
    assert Autenticacion.alcance_de_usuario(objetivo.id, empresa.id).branches_permitidos == []
  end

  test "agrega una sales unit y una inventory location de forma independiente de la sucursal", %{
    conn: conn,
    empresa: empresa,
    objetivo: objetivo,
    sales_unit: sales_unit,
    inventory_location: inventory_location
  } do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
    seleccionar(view, objetivo)

    view |> form("form[phx-submit=agregar_sales_unit_a_usuario]", %{"id" => to_string(sales_unit.id)}) |> render_submit()

    view
    |> form("form[phx-submit=agregar_inventory_location_a_usuario]", %{"id" => to_string(inventory_location.id)})
    |> render_submit()

    alcance = Autenticacion.alcance_de_usuario(objetivo.id, empresa.id)
    assert alcance.sales_units_permitidas == [sales_unit.id]
    assert alcance.inventory_locations_permitidas == [inventory_location.id]
    # La sucursal en sí no se tocó -- son 3 asignaciones independientes.
    assert alcance.branches_permitidos == []
  end

  test "marca y desmarca una sucursal asignada como default", %{conn: conn, empresa: empresa, objetivo: objetivo, branch: branch} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
    seleccionar(view, objetivo)
    view |> form("form[phx-submit=agregar_branch_a_usuario]", %{"id" => to_string(branch.id)}) |> render_submit()

    html = view |> element("button[phx-click=toggle_branch_default]") |> render_click()
    assert html =~ "★ Default"
    assert Autenticacion.defaults_de_usuario(objetivo.id, empresa.id).branch.id == branch.id

    html = view |> element("button[phx-click=toggle_branch_default]") |> render_click()
    assert html =~ "☆ Default"
    assert Autenticacion.defaults_de_usuario(objetivo.id, empresa.id).branch == nil
  end

  test "el botón Default no aparece para una sucursal todavía sin asignar", %{conn: conn, objetivo: objetivo} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
    html = seleccionar(view, objetivo)
    refute html =~ "phx-click=\"toggle_branch_default\""
  end

  test "la pestaña Empresas por separado ya no existe -- Empresa vive dentro de Alcance", %{conn: conn, objetivo: objetivo} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
    html = seleccionar(view, objetivo)
    refute html =~ "usuario-detalle-panel-empresas"
    assert html =~ "usuario-detalle-panel-alcance"
    assert html =~ "Empresa</h3>"
  end
end
