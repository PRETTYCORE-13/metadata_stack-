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
  import Ecto.Query

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.{Usuario, UsuarioEmpresa, UsuarioRol, UsuarioBranch}
  alias MetadataApp.Repo

  setup %{conn: conn} do
    admin = usuario_fixture()
    # crear_empresa_para_usuario/2 ya deja al creador como "administrador"
    # de esa empresa -- bypasea el gate sysadmin_usuarios/leer de esta
    # pantalla (y cualquier otro permiso vivo, ver Permissions.administrador?/2).
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
      admin: admin,
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

  defp scope_de(usuario, empresa) do
    %MetadataApp.Autenticacion.Scope{usuario: usuario, empresa_activa: empresa}
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

  describe "pestaña Sysadmin (switches de capacidad)" do
    test "prende y apaga el acceso a una pantalla puntual de Sysadmin", %{conn: conn, empresa: empresa, objetivo: objetivo} do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
      html = seleccionar(view, objetivo)

      refute html =~ ~s(aria-checked="true")
      refute MetadataApp.Permissions.can?(scope_de(objetivo, empresa), "leer", "sysadmin_roles")

      html =
        view
        |> element(~s(button[phx-click=toggle_capacidad_sysadmin][phx-value-recurso="sysadmin_roles"]))
        |> render_click()

      assert html =~ ~s(aria-checked="true")
      assert MetadataApp.Permissions.can?(scope_de(objetivo, empresa), "leer", "sysadmin_roles")

      html =
        view
        |> element(~s(button[phx-click=toggle_capacidad_sysadmin][phx-value-recurso="sysadmin_roles"]))
        |> render_click()

      refute html =~ ~s(aria-checked="true")
      refute MetadataApp.Permissions.can?(scope_de(objetivo, empresa), "leer", "sysadmin_roles")
    end

    test "prender un switch no habilita OTRA capacidad distinta", %{conn: conn, empresa: empresa, objetivo: objetivo} do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
      seleccionar(view, objetivo)

      view
      |> element(~s(button[phx-click=toggle_capacidad_sysadmin][phx-value-recurso="sysadmin_credenciales"]))
      |> render_click()

      assert MetadataApp.Permissions.can?(scope_de(objetivo, empresa), "leer", "sysadmin_credenciales")
      refute MetadataApp.Permissions.can?(scope_de(objetivo, empresa), "leer", "sysadmin_roles")
      refute MetadataApp.Permissions.can?(scope_de(objetivo, empresa), "leer", "sysadmin_jerarquia")
    end
  end

  describe "eliminar usuario (borrado total, SPEC-SYS-1709202601 R13a-e)" do
    test "elimina la cuenta por completo, sale de la lista y no puede volver a autenticarse", %{
      conn: conn,
      objetivo: objetivo
    } do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
      seleccionar(view, objetivo)

      html = view |> element("button[phx-click=eliminar_usuario]") |> render_click()

      # El flash de confirmación repite el email a propósito (le confirma
      # al admin A QUIÉN borró) -- lo que no debe quedar es el renglón de
      # la lista ni el panel de detalle abierto para ese usuario.
      refute html =~ "phx-value-id=\"#{objetivo.id}\""
      assert html =~ "Elegí un usuario de la izquierda."
      refute Repo.get(Usuario, objetivo.id)
    end

    test "eliminar un usuario con VARIAS empresas lo borra de todas, sin filas huérfanas", %{
      conn: conn,
      objetivo: objetivo
    } do
      {:ok, _otra_empresa} =
        Autenticacion.crear_empresa_para_usuario("Otra empresa del objetivo #{System.unique_integer()}", objetivo.id)

      assert length(Autenticacion.empresas_de_usuario(objetivo.id)) == 2

      {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
      seleccionar(view, objetivo)
      view |> element("button[phx-click=eliminar_usuario]") |> render_click()

      refute Repo.get(Usuario, objetivo.id)
      assert Repo.all(from ue in UsuarioEmpresa, where: ue.usuario_id == ^objetivo.id) == []
      assert Repo.all(from ur in UsuarioRol, where: ur.usuario_id == ^objetivo.id) == []
      assert Repo.all(from ub in UsuarioBranch, where: ub.usuario_id == ^objetivo.id) == []
    end

    test "el botón no aparece y el evento no tiene efecto sobre uno mismo", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
      html = seleccionar(view, admin)

      refute html =~ "phx-click=\"eliminar_usuario\""

      render_click(view, "eliminar_usuario", %{})
      assert Repo.get(Usuario, admin.id)
    end

    test "el botón no aparece y el evento no tiene efecto sobre un sysadmin de plataforma", %{
      conn: conn,
      objetivo: objetivo
    } do
      objetivo = objetivo |> Ecto.Changeset.change(super_admin: true) |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
      html = seleccionar(view, objetivo)

      refute html =~ "phx-click=\"eliminar_usuario\""

      render_click(view, "eliminar_usuario", %{})
      assert Repo.get(Usuario, objetivo.id)
    end
  end

  describe "pestaña Roles (picker de doble lista, SPEC-SYS-1709202601 R14-R16c)" do
    setup %{empresa: empresa} do
      {:ok, rol} = MetadataApp.Permissions.crear_rol(%{empresa_id: empresa.id, nombre: "Rol picker #{System.unique_integer()}"})
      %{rol: rol}
    end

    test "seleccionar un rol disponible y mover con -> lo concede de verdad", %{
      conn: conn,
      empresa: empresa,
      objetivo: objetivo,
      rol: rol
    } do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
      html = seleccionar(view, objetivo)
      assert html =~ ~s(phx-click="seleccionar_rol_disponible" phx-value-id="#{rol.id}")

      view |> element(~s(li[phx-click=seleccionar_rol_disponible][phx-value-id="#{rol.id}"])) |> render_click()
      html = view |> element("button[phx-click=mover_rol_a_concedidos]") |> render_click()

      assert rol.id in Enum.map(MetadataApp.Permissions.roles_de_usuario(objetivo.id, empresa.id), & &1.id)
      assert html =~ ~s(phx-click="seleccionar_rol_concedido" phx-value-id="#{rol.id}")
      refute html =~ ~s(phx-click="seleccionar_rol_disponible" phx-value-id="#{rol.id}")
    end

    test "seleccionar un rol concedido y mover con <- lo revoca de verdad", %{
      conn: conn,
      empresa: empresa,
      objetivo: objetivo,
      rol: rol
    } do
      MetadataApp.Permissions.asignar_rol(objetivo.id, rol.id, empresa.id)

      {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
      seleccionar(view, objetivo)

      view |> element(~s(li[phx-click=seleccionar_rol_concedido][phx-value-id="#{rol.id}"])) |> render_click()
      html = view |> element("button[phx-click=mover_rol_a_disponibles]") |> render_click()

      refute rol.id in Enum.map(MetadataApp.Permissions.roles_de_usuario(objetivo.id, empresa.id), & &1.id)
      assert html =~ ~s(phx-click="seleccionar_rol_disponible" phx-value-id="#{rol.id}")
      refute html =~ ~s(phx-click="seleccionar_rol_concedido" phx-value-id="#{rol.id}")
    end

    test "un click de flecha sin nada seleccionado no concede ni revoca nada", %{
      conn: conn,
      empresa: empresa,
      objetivo: objetivo,
      rol: rol
    } do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
      seleccionar(view, objetivo)

      render_click(view, "mover_rol_a_concedidos", %{})
      render_click(view, "mover_rol_a_disponibles", %{})

      refute rol.id in Enum.map(MetadataApp.Permissions.roles_de_usuario(objetivo.id, empresa.id), & &1.id)
    end

    test "\"Quitar todos\" revoca TODOS los roles concedidos de una sola vez", %{
      conn: conn,
      empresa: empresa,
      objetivo: objetivo,
      rol: rol
    } do
      {:ok, otro_rol} = MetadataApp.Permissions.crear_rol(%{empresa_id: empresa.id, nombre: "Rol picker 2 #{System.unique_integer()}"})
      MetadataApp.Permissions.asignar_rol(objetivo.id, rol.id, empresa.id)
      MetadataApp.Permissions.asignar_rol(objetivo.id, otro_rol.id, empresa.id)

      {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
      seleccionar(view, objetivo)

      html = view |> element("button[phx-click=quitar_todos_los_roles]") |> render_click()

      assert MetadataApp.Permissions.roles_de_usuario(objetivo.id, empresa.id) == []
      assert html =~ "Sin roles todavía."
    end

    test "\"Quitar todos\" sale deshabilitado cuando el usuario no tiene roles", %{conn: conn, objetivo: objetivo} do
      {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
      html = seleccionar(view, objetivo)

      assert html =~ ~s(phx-click="quitar_todos_los_roles" disabled)
    end

    # R16f: después de asignar con "→", el foco pasa solo al PRIMER rol que
    # queda disponible -- así clickear la flecha otra vez (sin volver a
    # seleccionar nada a mano) asigna el rol SIGUIENTE, no ninguno.
    test "después de asignar un rol, clickear -> otra vez asigna el próximo sin volver a seleccionar", %{
      conn: conn,
      empresa: empresa,
      objetivo: objetivo,
      rol: rol
    } do
      {:ok, otro_rol} = MetadataApp.Permissions.crear_rol(%{empresa_id: empresa.id, nombre: "AAA rol picker 2 #{System.unique_integer()}"})

      {:ok, view, _html} = live(conn, ~p"/sysadmin/usuarios")
      seleccionar(view, objetivo)

      view |> element(~s(li[phx-click=seleccionar_rol_disponible][phx-value-id="#{rol.id}"])) |> render_click()
      view |> element("button[phx-click=mover_rol_a_concedidos]") |> render_click()

      # Sin seleccionar nada a mano -- si el foco quedó puesto solo, este
      # segundo click también tiene que asignar (el botón no debe seguir
      # disabled, y del lado servidor rol_disponible_seleccionado_id no es
      # nil). NO se puede aserter "Sin roles disponibles." acá -- "administrador"
      # es un rol global (empresa_id nil, sembrado por migración) que SIEMPRE
      # queda disponible salvo que se lo asignen explícitamente.
      view |> element("button[phx-click=mover_rol_a_concedidos]") |> render_click()

      concedidos_ids = Enum.map(MetadataApp.Permissions.roles_de_usuario(objetivo.id, empresa.id), & &1.id)
      assert rol.id in concedidos_ids
      assert otro_rol.id in concedidos_ids
    end
  end
end
