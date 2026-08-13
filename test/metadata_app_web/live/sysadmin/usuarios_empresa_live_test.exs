defmodule MetadataAppWeb.Sysadmin.UsuariosEmpresaLiveTest do
  @moduledoc """
  Pestaña "Alcance" de UsuariosEmpresaLive (Fase 7 del modelo de Alcance
  de Datos, 2026-08-11; rediseñada 2026-08-13 -- arquitectura ERP,
  Empresa -> N Branch -> N Inventory -> N Sales Unit, Sales Unit
  opcional, a pedido explícito con mockup). Ya no son 4 listas planas
  (rediseño 2026-08-12): la pestaña es GLOBAL al usuario (todas sus
  empresas, no solo la que está "en foco" en esta pantalla) y anidada --
  un bloque por empresa, con sus sucursales asignadas adentro, y cada
  sucursal con SU PROPIO Almacén/Unidad de venta adentro (un almacén
  pertenece a una sola sucursal). Almacén/Unidad de venta ya no se pueden
  asignar sin haber asignado la sucursal primero -- el picker ni existe
  todavía sin eso.
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

  # Arquitectura ERP (2026-08-13): Almacén/Unidad de venta ya NO son
  # independientes de la sucursal -- el picker de cada uno vive ANIDADO
  # dentro de la card de la sucursal ya asignada (un almacén pertenece a
  # una sola branch). Antes de esto se podían asignar sueltos, sin
  # sucursal -- ya no tiene sentido, así que este test ahora asigna la
  # sucursal primero.
  test "agrega una sales unit y una inventory location anidadas a su sucursal", %{
    conn: conn,
    empresa: empresa,
    objetivo: objetivo,
    branch: branch,
    sales_unit: sales_unit,
    inventory_location: inventory_location
  } do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
    seleccionar(view, objetivo)

    view |> form("form[phx-submit=agregar_branch_a_usuario]", %{"id" => to_string(branch.id)}) |> render_submit()

    view |> form("form[phx-submit=agregar_sales_unit_a_usuario]", %{"id" => to_string(sales_unit.id)}) |> render_submit()

    view
    |> form("form[phx-submit=agregar_inventory_location_a_usuario]", %{"id" => to_string(inventory_location.id)})
    |> render_submit()

    alcance = Autenticacion.alcance_de_usuario(objetivo.id, empresa.id)
    assert alcance.branches_permitidos == [branch.id]
    assert alcance.sales_units_permitidas == [sales_unit.id]
    assert alcance.inventory_locations_permitidas == [inventory_location.id]
  end

  test "el picker de Almacén/Unidad de venta no existe todavía sin sucursal asignada", %{conn: conn, objetivo: objetivo} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
    html = seleccionar(view, objetivo)

    refute html =~ "phx-submit=\"agregar_sales_unit_a_usuario\""
    refute html =~ "phx-submit=\"agregar_inventory_location_a_usuario\""
  end

  test "marca y desmarca una sucursal asignada como default", %{conn: conn, empresa: empresa, objetivo: objetivo, branch: branch} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
    seleccionar(view, objetivo)
    view |> form("form[phx-submit=agregar_branch_a_usuario]", %{"id" => to_string(branch.id)}) |> render_submit()

    # Rediseño 2026-08-13 ("respeta mi bosquejo"): ya no hay texto
    # "★/☆ Default", es un punto verde (● bg-green-500) -- la advertencia
    # "falta default" (siempre visible mientras haya sucursales sin
    # default) es la señal de texto más estable para el assert.
    html = view |> element("button[phx-click=toggle_branch_default]") |> render_click()
    refute html =~ "falta default"
    assert Autenticacion.branch_default_de_usuario(objetivo.id, empresa.id).id == branch.id

    html = view |> element("button[phx-click=toggle_branch_default]") |> render_click()
    assert html =~ "falta default"
    assert Autenticacion.branch_default_de_usuario(objetivo.id, empresa.id) == nil
  end

  # Sucursal es obligatoria (arquitectura ERP, 2026-08-13) -- el botón
  # Default de Sucursal ahora muestra una advertencia si hay sucursales
  # asignadas pero ninguna es default, en vez de solo faltar el botón.
  test "marca y desmarca un almacén asignado (dentro de su sucursal) como default", %{
    conn: conn,
    objetivo: objetivo,
    branch: branch,
    inventory_location: inventory_location
  } do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
    seleccionar(view, objetivo)
    view |> form("form[phx-submit=agregar_branch_a_usuario]", %{"id" => to_string(branch.id)}) |> render_submit()

    view
    |> form("form[phx-submit=agregar_inventory_location_a_usuario]", %{"id" => to_string(inventory_location.id)})
    |> render_submit()

    # Rediseño 2026-08-13 ("respeta mi bosquejo"): el marcador es un
    # punto verde (bg-green-500), no texto "★/☆ Default" -- nada más en
    # esta página lo usa todavía en este punto del test (nadie tiene
    # ningún default fijado), así que sirve como señal directa.
    html = view |> element("button[phx-click=toggle_inventory_default]") |> render_click()
    assert html =~ "bg-green-500"
    assert Autenticacion.defaults_de_branch(objetivo.id, branch.id).inventory_location.id == inventory_location.id

    html = view |> element("button[phx-click=toggle_inventory_default]") |> render_click()
    refute html =~ "bg-green-500"
    assert Autenticacion.defaults_de_branch(objetivo.id, branch.id).inventory_location == nil
  end

  test "el botón Default no aparece para una sucursal todavía sin asignar", %{conn: conn, objetivo: objetivo} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
    html = seleccionar(view, objetivo)
    refute html =~ "phx-click=\"toggle_branch_default\""
  end

  test "advierte cuando hay sucursales asignadas pero ninguna es default", %{conn: conn, objetivo: objetivo, branch: branch} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
    seleccionar(view, objetivo)

    html =
      view
      |> form("form[phx-submit=agregar_branch_a_usuario]", %{"id" => to_string(branch.id)})
      |> render_submit()

    assert html =~ "falta default"
  end

  test "la pestaña Empresas por separado ya no existe -- Empresa vive dentro de Alcance", %{conn: conn, objetivo: objetivo} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
    html = seleccionar(view, objetivo)
    refute html =~ "usuario-detalle-panel-empresas"
    assert html =~ "usuario-detalle-panel-alcance"
    assert html =~ "Empresa</h3>"
  end
end
