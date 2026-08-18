defmodule MetadataAppWeb.FichaLiveAccionExternaTest do
  @moduledoc """
  Fase 6 de "Integraciones" (2026-08-07) — prueba de punta a punta del
  botón interactivo en la Ficha 360°: click real -> start_async/3 ->
  Integraciones.ejecutar_accion/4 -> llamada de red real a httpbin.org ->
  modal con la respuesta cruda. Mismo criterio de la Fase 4/5: sin mocks.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
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

    %{conn: conn, empresa: empresa}
  end

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])
  defp header_clientes, do: Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")

  defp fixture_cliente(estado_id \\ nil) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(%{
      meta_fixture_cliente_nombre: "cliente accion externa #{unique()}",
      meta_fixture_cliente_edad: 30,
      meta_fixture_cliente_venta: Decimal.new("100.00")
    })
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Ecto.Changeset.put_change(:estado_id, estado_id)
    |> Repo.insert!()
  end

  defp fixture_credencial do
    {:ok, credencial} =
      Integraciones.crear_credencial(%{
        nombre: "httpbin fixture #{unique()}",
        sistema_externo: "httpbin",
        api_key_nuevo: "clave-de-prueba",
        base_url: "https://httpbin.org"
      })

    credencial
  end

  defp fixture_accion(header, credencial, attrs \\ %{}) do
    base = %{
      meta_schema_header_id: header.id,
      credencial_id: credencial.id,
      nombre: "consultar_externo",
      etiqueta: "Consultar externo",
      metodo: "GET",
      url_template: "{base_url}/get"
    }

    {:ok, accion} = Integraciones.crear_accion(Map.merge(base, attrs))
    accion
  end

  @tag :external_http
  test "click real en el botón ejecuta la acción y muestra la respuesta cruda en el modal", %{conn: conn} do
    header = header_clientes()
    credencial = fixture_credencial()
    fixture_accion(header, credencial)
    cliente = fixture_cliente()

    {:ok, view, html} = live(conn, "/registro/meta_fixture_cliente/#{cliente.id}")

    assert html =~ "Consultar externo"
    refute html =~ "HTTP 200"

    view |> element("button[phx-click=ejecutar_accion_externa]", "Consultar externo") |> render_click()

    # start_async/3 corre el Task fuera del proceso de la LiveView --
    # render_async/1 espera a que termine antes de seguir (mismo patrón
    # que ya usa el suite de BcList para "confirmar_publicar").
    html = render_async(view, 10_000)

    assert html =~ "HTTP 200"
    assert html =~ "httpbin.org"
  end

  test "una acción con confirmar_antes trae el data-confirm en el botón", %{conn: conn} do
    header = header_clientes()
    credencial = fixture_credencial()
    fixture_accion(header, credencial, %{nombre: "borrar_externo", etiqueta: "Borrar externo", metodo: "DELETE", confirmar_antes: true})
    cliente = fixture_cliente()

    {:ok, _view, html} = live(conn, "/registro/meta_fixture_cliente/#{cliente.id}")

    assert html =~ "Borrar externo"
    assert html =~ "data-confirm"
  end

  test "una acción que falla (host inválido) muestra el error en el modal, sin romper la ficha", %{conn: conn} do
    header = header_clientes()
    credencial = fixture_credencial()
    fixture_accion(header, credencial, %{nombre: "falla_externo", etiqueta: "Falla externo", url_template: "https://esto-no-existe.invalid/x"})
    cliente = fixture_cliente()

    {:ok, view, _html} = live(conn, "/registro/meta_fixture_cliente/#{cliente.id}")

    view |> element("button[phx-click=ejecutar_accion_externa]", "Falla externo") |> render_click()
    html = render_async(view, 10_000)

    assert html =~ "Falla externo"
    refute html =~ "HTTP 200"
  end

  # Fase 7 ("Integraciones") — sin el permiso {recurso: catálogo, accion:
  # "ejecutar_<nombre>"}, el botón ni siquiera aparece (mismo criterio que
  # las transiciones RBAC del motor de estados: deny-by-default, oculto
  # por completo, no deshabilitado con tooltip). Acá el usuario tiene
  # empresa activa (pasa el on_mount de sesión) pero NINGÚN rol asignado
  # -- permisos_de_usuario/2 devuelve lista vacía, can?/3 da false para
  # cualquier {accion, recurso}.
  test "sin el permiso ejecutar_<nombre>, el botón no aparece y el evento se rechaza", %{empresa: empresa} do
    header = header_clientes()
    credencial = fixture_credencial()
    fixture_accion(header, credencial, %{nombre: "restringido_externo", etiqueta: "Restringido externo"})
    cliente = fixture_cliente()

    usuario_sin_rol = usuario_fixture()

    {:ok, _} =
      %UsuarioEmpresa{}
      |> UsuarioEmpresa.changeset(%{usuario_id: usuario_sin_rol.id, empresa_id: empresa.id})
      |> Repo.insert()

    conn_sin_rol =
      build_conn()
      |> log_in_usuario(usuario_sin_rol)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    {:ok, view, html} = live(conn_sin_rol, "/registro/meta_fixture_cliente/#{cliente.id}")

    refute html =~ "Restringido externo"

    # Ni mandando el evento a mano (bypaseando el botón que el HTML ya no
    # tiene) se puede forzar la ejecución -- ver el re-chequeo defensivo en
    # handle_event("ejecutar_accion_externa", ...).
    accion = Repo.get_by!(Integraciones.AccionExterna, nombre: "restringido_externo")
    html = render_click(view, "ejecutar_accion_externa", %{"accion_id" => to_string(accion.id)})

    assert html =~ "No tienes permiso"
  end
end
