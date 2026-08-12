defmodule MetadataAppWeb.JerarquiaOperativaTest do
  @moduledoc """
  Fase 6 de la jerarquía operativa activa (2026-08-11, extensión sobre el
  modelo de Alcance de Datos) — de punta a punta vía HTTP real (login,
  selector de la banda de pie, pantalla de selección): confirma que
  branch_activo/inventory_location_activo/sales_unit_activo se auto-
  activan, se pueden cambiar, y nunca bloquean la navegación normal.

  A propósito NO ejercita la creación de un registro con autocompletado
  vía la API HTTP (eso exigiría un catálogo real generado con
  CatalogoGenerador.generar/1 dentro del test -- DDL real corriendo
  contra el Sandbox transaccional, el mismo tipo de operación que ya se
  decidió mantener fuera del suite automatizado en Fase 9, ver el
  moduledoc de AlcanceDatosPorCatalogoUiTest). Esa lógica de
  autocompletado/bloqueo ya está probada de punta a punta, con Postgres
  real, en CatalogoGenerico directo -- ver
  alcance_de_datos_escritura_test.exs, describe "crear/4 — alcance_tipo
  :branch". Acá se prueba lo que ESE archivo no cubre: la sesión HTTP.
  """
  use MetadataAppWeb.ConnCase, async: true

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion

  defp set_password_e_iniciar(conn, usuario) do
    usuario = set_password(usuario)

    post(conn, ~p"/meta_schema_usuario/log-in", %{
      "usuario" => %{"email" => usuario.email, "password" => valid_usuario_password()}
    })
  end

  test "login con exactamente 1 branch/1 inventory permitidos los auto-activa, sin pantalla de más", %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa jerarquia op 1 #{System.unique_integer()}", usuario.id)
    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})
    {:ok, inventory} = Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Producto terminado"})
    Autenticacion.asignar_branch(usuario.id, branch.id)
    Autenticacion.asignar_inventory_location(usuario.id, inventory.id)

    conn = set_password_e_iniciar(conn, usuario)

    # Va directo a la app -- NUNCA a seleccionar-jerarquia, aunque
    # técnicamente "hay" jerarquía que resolver (1 sola opción = se
    # activa sola).
    assert redirected_to(conn) == ~p"/sysadmin/bc-list"
    assert get_session(conn, :branch_activo_id) == branch.id
    assert get_session(conn, :inventory_location_activo_id) == inventory.id

    # El selector de la banda de pie muestra la selección ya hecha.
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "Toluca"
    assert html =~ "Producto terminado"
  end

  test "login con 2+ branches permitidos NO bloquea la navegación (branch_activo queda sin elegir)", %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa jerarquia op 2 #{System.unique_integer()}", usuario.id)
    {:ok, branch_a} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})
    {:ok, branch_b} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Puebla"})
    Autenticacion.asignar_branch(usuario.id, branch_a.id)
    Autenticacion.asignar_branch(usuario.id, branch_b.id)

    conn = set_password_e_iniciar(conn, usuario)

    # Hallazgo real de esta sesión (ver historial): la primera versión
    # SÍ bloqueaba acá, mandando a /seleccionar-jerarquia -- eso rompía
    # el login de CUALQUIER usuario sin jerarquía configurada (el caso de
    # HOY, nadie la tiene todavía). Corregido antes de llegar a
    # producción -- este test existe para que no vuelva a pasar.
    assert redirected_to(conn) == ~p"/sysadmin/bc-list"
    refute get_session(conn, :branch_activo_id)
  end

  test "login sin NINGÚN branch/inventory asignado tampoco bloquea la navegación", %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, _empresa} = Autenticacion.crear_empresa_para_usuario("Empresa jerarquia op 3 #{System.unique_integer()}", usuario.id)

    conn = set_password_e_iniciar(conn, usuario)

    assert redirected_to(conn) == ~p"/sysadmin/bc-list"
    refute get_session(conn, :branch_activo_id)
    refute get_session(conn, :inventory_location_activo_id)
  end

  test "el selector de la banda de pie cambia el branch activo y vuelve a la página de origen", %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa jerarquia op 4 #{System.unique_integer()}", usuario.id)
    {:ok, branch_a} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})
    {:ok, branch_b} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Puebla"})
    Autenticacion.asignar_branch(usuario.id, branch_a.id)
    Autenticacion.asignar_branch(usuario.id, branch_b.id)

    conn = set_password_e_iniciar(conn, usuario)
    refute get_session(conn, :branch_activo_id)

    conn =
      conn
      |> recycle()
      |> Plug.Conn.put_req_header("referer", "http://localhost/sysadmin/bc-list")
      |> post(~p"/meta_schema_usuario/branch/activar", %{"id" => to_string(branch_b.id)})

    assert get_session(conn, :branch_activo_id) == branch_b.id
    assert redirected_to(conn) == "/sysadmin/bc-list"
  end

  test "el selector de la banda de pie rechaza un branch al que el usuario no tiene acceso", %{conn: conn} do
    # crear_empresa_para_usuario/2 deja al creador como "administrador"
    # (comodín que ahora TAMBIÉN bypasea el selector de jerarquía
    # operativa, ver Autenticacion.resolver_jerarquia_operativa/3) --
    # la jerarquía la arma un "dueño" descartable, nunca el usuario bajo
    # prueba, mismo criterio ya establecido en los tests de Alcance de
    # Datos (Fase 4a/4b).
    dueno = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa jerarquia op 5 #{System.unique_integer()}", dueno.id)
    {:ok, branch_permitida} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})
    {:ok, branch_ajena} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Puebla"})

    usuario = usuario_fixture()
    Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)
    Autenticacion.asignar_branch(usuario.id, branch_permitida.id)

    conn = set_password_e_iniciar(conn, usuario)
    assert get_session(conn, :branch_activo_id) == branch_permitida.id

    conn = post(conn, ~p"/meta_schema_usuario/branch/activar", %{"id" => to_string(branch_ajena.id)})

    # Rechazado en silencio (flash de error), sin pisar la selección
    # válida que ya tenía.
    assert get_session(conn, :branch_activo_id) == branch_permitida.id
  end

  test "sales_unit_activo se puede apagar explícitamente eligiendo 'Ninguna'", %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa jerarquia op 6 #{System.unique_integer()}", usuario.id)
    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})
    {:ok, sales_unit} = Autenticacion.crear_sales_unit(%{empresa_id: empresa.id, branch_id: branch.id, sales_unit_name: "Preventa 1"})
    Autenticacion.asignar_sales_unit(usuario.id, sales_unit.id)

    conn = set_password_e_iniciar(conn, usuario)
    assert get_session(conn, :sales_unit_activo_id) == sales_unit.id

    conn = post(conn, ~p"/meta_schema_usuario/sales-unit/activar", %{"id" => "ninguna"})

    refute get_session(conn, :sales_unit_activo_id)
  end

  test "/seleccionar-jerarquia muestra las opciones pendientes y permite elegir todas juntas", %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa jerarquia op 7 #{System.unique_integer()}", usuario.id)
    {:ok, branch_a} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})
    {:ok, branch_b} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Puebla"})
    {:ok, inventory} = Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch_a.id, inventory_name: "Producto terminado"})
    Autenticacion.asignar_branch(usuario.id, branch_a.id)
    Autenticacion.asignar_branch(usuario.id, branch_b.id)
    Autenticacion.asignar_inventory_location(usuario.id, inventory.id)

    conn = set_password_e_iniciar(conn, usuario)
    refute get_session(conn, :branch_activo_id)
    # inventory sí se auto-activó (1 sola opción) -- el form todavía
    # tiene que mandarlo (como hidden input) junto con el branch elegido.
    assert get_session(conn, :inventory_location_activo_id) == inventory.id

    conn = get(conn, ~p"/meta_schema_usuario/seleccionar-jerarquia")
    html = html_response(conn, 200)
    assert html =~ "Toluca"
    assert html =~ "Puebla"

    conn =
      post(conn, ~p"/meta_schema_usuario/jerarquia/activar", %{
        "branch_id" => to_string(branch_a.id),
        "inventory_location_id" => to_string(inventory.id)
      })

    assert get_session(conn, :branch_activo_id) == branch_a.id
    assert get_session(conn, :inventory_location_activo_id) == inventory.id
  end
end
