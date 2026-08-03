defmodule MetadataAppWeb.FichaLiveAuditoriaTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.MetaSchema.Auditoria
  alias MetadataApp.Permissions

  import Ecto.Query

  # Prueba de integración real (roadmap #6, Fase 2): confirma que
  # get_connect_info/2 en FichaLive.mount/3 no explota bajo un socket
  # conectado de verdad (LiveViewTest simula el mismo protocolo que un
  # browser real) y que el contexto que arma AuditoriaContexto.desde_socket/1
  # (usuario/ip/user-agent) efectivamente llega hasta la fila de auditoría.
  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa auditoria test #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
      |> Plug.Conn.put_req_header("user-agent", "prueba-auditoria-e2e")

    %{conn: conn, usuario: usuario}
  end

  test "alta real vía FichaLive queda auditada con usuario/ip/user-agent", %{conn: conn, usuario: usuario} do
    {:ok, view, _html} = live(conn, "/registro/meta_fixture_cliente/nuevo")

    campos = %{
      "meta_fixture_cliente_nombre" => "Aud E2E",
      "meta_fixture_cliente_edad" => "30",
      "meta_fixture_cliente_venta" => "100.50"
    }

    # El form ya no lee los valores directo del submit -- "validar" (phx-change)
    # los mantiene en vivo en @form_values (para que "Guardar" funcione parado
    # en cualquier tab, no solo en "Datos") -- un browser real ya dispara esto
    # solo mientras el usuario tipea, acá hay que simularlo antes de enviar.
    render_change(view, "validar", %{"campos" => campos})

    view
    |> form("#form-ficha-datos", %{"campos" => campos})
    |> render_submit()

    assert_redirect(view)

    fila =
      Auditoria
      |> where([a], a.bc == "meta_fixture_cliente" and a.operacion == "alta")
      |> order_by(desc: :id)
      |> limit(1)
      |> Repo.one!()

    assert fila.usuario_email == usuario.email
    assert fila.ip != nil
    assert fila.user_agent == "prueba-auditoria-e2e"
    assert fila.datos["despues"]["meta_fixture_cliente_nombre"] == "Aud E2E"
  end

  # Regresión real: cargar_registro/2 (llamada al VER un registro YA
  # persistido, a diferencia de "/nuevo" arriba) se quedó sin el assign
  # :detalle_renglones_eliminados al agregar el soft-delete directo de
  # renglones — KeyError en cualquier ficha existente, encontrado en vivo
  # por el usuario. LiveViewTest simula el mismo protocolo que un browser
  # real, así que este mount es la forma correcta de agarrar este tipo de
  # bug (el suite completo no lo detectaba porque no había ningún test
  # que viera un registro EXISTENTE, solo "/nuevo").
  test "ver un registro ya persistido no explota (KeyError detalle_renglones_eliminados)", %{conn: conn} do
    campos = %{
      "meta_fixture_cliente_nombre" => "Ver Existente",
      "meta_fixture_cliente_edad" => "40",
      "meta_fixture_cliente_venta" => "10.00"
    }

    {:ok, view, _html} = live(conn, "/registro/meta_fixture_cliente/nuevo")
    render_change(view, "validar", %{"campos" => campos})
    view |> form("#form-ficha-datos", %{"campos" => campos}) |> render_submit()
    assert_redirect(view)

    registro =
      MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
      |> where([r], r.meta_fixture_cliente_nombre == "Ver Existente")
      |> order_by(desc: :id)
      |> limit(1)
      |> Repo.one!()

    assert {:ok, _view, html} = live(conn, "/registro/meta_fixture_cliente/#{registro.id}")
    assert html =~ "Ver Existente"
  end
end
