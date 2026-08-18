defmodule MetadataAppWeb.Sysadmin.AccionesExternasLiveTest do
  @moduledoc """
  Fase 6 de "Integraciones" (2026-08-07) — CRUD real de la pantalla de
  administración de Acciones externas, incluyendo el textarea JSON de
  headers_template (el único campo sin un input HTML nativo -- ver
  AccionesExternasLive.parsear_headers/1).
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, Scope, UsuarioEmpresa}
  alias MetadataApp.Permissions
  alias MetadataApp.Integraciones

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa fixture #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    {:ok, credencial} =
      Integraciones.crear_credencial(%{
        nombre: "credencial fixture #{System.unique_integer()}",
        api_key_nuevo: "clave",
        base_url: "https://httpbin.org"
      })

    %{conn: conn, credencial: credencial, usuario: usuario, empresa: empresa}
  end

  test "crea una acción con headers JSON válidos", %{conn: conn, credencial: credencial} do
    {:ok, view, _html} = live(conn, "/sysadmin/acciones-externas")

    view |> element("button", "+ Nueva acción") |> render_click()

    html =
      view
      |> form("form[phx-submit=guardar_accion]", %{
        "accion_externa" => %{
          "nombre" => "crear_test",
          "etiqueta" => "Crear test",
          "credencial_id" => credencial.id,
          "metodo" => "POST",
          "url_template" => "{base_url}/post"
        },
        "headers_template_texto" => ~s({"Content-Type": "application/json"})
      })
      |> render_submit()

    assert html =~ "guardada"
    accion = Repo.get_by!(Integraciones.AccionExterna, nombre: "crear_test")
    assert accion.headers_template == %{"Content-Type" => "application/json"}
    assert accion.credencial_id == credencial.id
  end

  test "un JSON inválido en headers muestra el error sin guardar", %{conn: conn, credencial: credencial} do
    {:ok, view, _html} = live(conn, "/sysadmin/acciones-externas")

    view |> element("button", "+ Nueva acción") |> render_click()

    html =
      view
      |> form("form[phx-submit=guardar_accion]", %{
        "accion_externa" => %{
          "nombre" => "invalido_test",
          "credencial_id" => credencial.id,
          "metodo" => "GET",
          "url_template" => "{base_url}/get"
        },
        "headers_template_texto" => "esto no es json"
      })
      |> render_submit()

    assert html =~ "JSON inválido"
    refute Repo.get_by(Integraciones.AccionExterna, nombre: "invalido_test")
  end

  test "elimina una acción existente", %{conn: conn, credencial: credencial} do
    {:ok, accion} =
      Integraciones.crear_accion(%{
        nombre: "borrar_test",
        credencial_id: credencial.id,
        metodo: "GET",
        url_template: "{base_url}/get"
      })

    {:ok, view, _html} = live(conn, "/sysadmin/acciones-externas")

    view |> element("button", "borrar_test") |> render_click()
    html = view |> element("button", "Eliminar") |> render_click()

    assert html =~ "eliminada"
    assert Repo.get(Integraciones.AccionExterna, accion.id).delete_guid != nil
  end

  # Fase 8 ("Integraciones") — el panel "Últimas ejecuciones" (acá) y el
  # badge de la lista de CredencialesLive (test aparte, mismo archivo de
  # abajo) tienen que reflejar ejecuciones REALES, no un mock — mismo
  # criterio de la Fase 4/5/6: llamadas de red reales a httpbin.org.
  @tag :external_http
  test "el panel de últimas ejecuciones muestra corridas reales (éxito y error)", %{
    conn: conn,
    credencial: credencial,
    usuario: usuario,
    empresa: empresa
  } do
    header = Repo.get_by!(MetadataApp.BusinessProcessBuilder.MetaSchema.Header, schema_context_name: "meta_fixture_cliente")

    {:ok, accion} =
      Integraciones.crear_accion(%{
        meta_schema_header_id: header.id,
        credencial_id: credencial.id,
        nombre: "log_test",
        etiqueta: "Log test",
        metodo: "GET",
        url_template: "{base_url}/status/200"
      })

    registro =
      %MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente{}
      |> MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente.changeset(%{
        meta_fixture_cliente_nombre: "cliente log #{System.unique_integer([:positive])}",
        meta_fixture_cliente_edad: 30,
        meta_fixture_cliente_venta: Decimal.new("1.00")
      })
      |> Ecto.Changeset.put_change(:insert_guid, Ecto.UUID.generate() |> String.replace("-", ""))
      |> Repo.insert!()

    scope = %Scope{usuario: usuario, empresa_activa: empresa}
    {:ok, %{status: 200}} = Integraciones.ejecutar_accion(accion, registro, scope)
    {:error, _} = Integraciones.ejecutar_accion(%{accion | url_template: "https://esto-no-existe.invalid/x"}, registro, :sistema)

    {:ok, view, _html} = live(conn, "/sysadmin/acciones-externas")
    html = view |> element("button", "Log test") |> render_click()

    assert html =~ "Últimas ejecuciones"
    assert html =~ "HTTP 200"
    assert html =~ "usuario"
    assert html =~ "regla_post"
  end

  @tag :external_http
  test "el badge de CredencialesLive refleja las ejecuciones de los últimos 7 días", %{conn: conn, credencial: credencial} do
    header = Repo.get_by!(MetadataApp.BusinessProcessBuilder.MetaSchema.Header, schema_context_name: "meta_fixture_cliente")

    {:ok, accion} =
      Integraciones.crear_accion(%{
        meta_schema_header_id: header.id,
        credencial_id: credencial.id,
        nombre: "badge_test",
        metodo: "GET",
        url_template: "{base_url}/status/200"
      })

    registro =
      %MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente{}
      |> MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente.changeset(%{
        meta_fixture_cliente_nombre: "cliente badge #{System.unique_integer([:positive])}",
        meta_fixture_cliente_edad: 30,
        meta_fixture_cliente_venta: Decimal.new("1.00")
      })
      |> Ecto.Changeset.put_change(:insert_guid, Ecto.UUID.generate() |> String.replace("-", ""))
      |> Repo.insert!()

    {:ok, %{status: 200}} = Integraciones.ejecutar_accion(accion, registro, :sistema)

    {:ok, _view, html} = live(conn, "/sysadmin/credenciales")

    assert html =~ "1/1 ok (7d)"
  end
end
