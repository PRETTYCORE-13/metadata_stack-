defmodule MetadataAppWeb.Sysadmin.AlcanceDatosPorCatalogoUiTest do
  @moduledoc """
  Fase 6 del modelo de Alcance de Datos (2026-08-11) — de punta a punta,
  vía clicks reales: elegir un `alcance_tipo` por rol en
  CatalogoPermisosLive, y confirmar que `Permissions.alcance_tipo_efectivo/2`
  (el que de verdad usa CatalogoGenerico en las Fases 4a/4b) refleja la
  elección.

  El toggle "Alcance de datos" de BcMotorLive (prender `alcance_habilitado`)
  NO tiene un test automatizado acá a propósito -- desde Fase 9
  (2026-08-11) ese click dispara `CatalogoGenerador.generar/1` de verdad
  (ALTER TABLE + recompilar el schema Ecto en caliente, ver
  `CatalogoGenerador.asegurar_columnas_alcance/1`). Probado así, bajo
  Ecto.Adapters.SQL.Sandbox (transaccional, nunca commitea hasta el
  rollback final del test), el ALTER TABLE queda invisible para
  CUALQUIER otra conexión/proceso -- y `BcMotorLive` renderiza un
  `PlantillaConstructorLive` anidado que consulta el catálogo con el
  schema YA recompilado (branch_id incluido) contra una conexión que
  puede no ver ese commit todavía, tronando con `undefined_column`. No es
  una condición de carrera evitable con `async: false` ni con un catálogo
  dedicado (se probaron ambos) -- es una incompatibilidad de fondo entre
  Sandbox transaccional y DDL en caliente. Mismo criterio ya establecido
  en este proyecto para `CatalogoGenerador.generar/1` en general (nunca
  tuvo cobertura automatizada, siempre validado manual/interactivo, ver
  memoria del proyecto) -- la prueba real de que el toggle provisiona las
  4 columnas y que el enforcement de lectura/escritura funciona de punta
  a punta sobre un catálogo generado de verdad se corrió a mano
  (`mix run`, sin sandbox, un catálogo descartable creado y eliminado con
  `CatalogoGenerador.generar/1`/`eliminar/3`) durante la sesión que
  implementó Fase 9.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, Scope, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.Permissions

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa alcance UI #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn, empresa: empresa}
  end

  test "elegir un alcance_tipo por rol en CatalogoPermisosLive queda reflejado en Permissions.alcance_tipo_efectivo/2", %{
    conn: conn,
    empresa: empresa
  } do
    header = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")
    {:ok, header} = MetadataApp.BusinessProcessBuilder.MetaSchemaContext.actualizar_header(header, %{"alcance_habilitado" => true})

    {:ok, rol} = Permissions.crear_rol(%{empresa_id: empresa.id, nombre: "Vendedor #{System.unique_integer()}"})
    otro_usuario = usuario_fixture()
    {:ok, _} = Permissions.asignar_rol(otro_usuario.id, rol.id, empresa.id)

    # "Alcance de datos por rol" solo lista roles con al menos un permiso
    # concedido sobre el catálogo (o "administrador") -- sin esto la fila
    # #alcance-rol-<id> no existe y el form de más abajo no encuentra nada.
    {:ok, _} = Permissions.conceder_permiso_catalogo(rol.id, "meta_fixture_cliente", "leer")

    {:ok, view, html} = live(conn, ~p"/sysadmin/catalogos/meta_fixture_cliente/permisos")
    assert html =~ "Alcance de datos por rol"
    assert html =~ rol.nombre

    view
    |> form("#alcance-rol-#{rol.id}", %{"rol_id" => to_string(rol.id), "tipo" => "branch"})
    |> render_change()

    scope = %Scope{usuario: otro_usuario, empresa_activa: empresa}
    assert Permissions.alcance_tipo_efectivo(scope, header.id) == :branch

    # Vuelve a apagar el catálogo para no dejar el fixture compartido
    # modificado para el resto de la sesión de tests.
    {:ok, _} = MetadataApp.BusinessProcessBuilder.MetaSchemaContext.actualizar_header(header, %{"alcance_habilitado" => false})
  end
end
