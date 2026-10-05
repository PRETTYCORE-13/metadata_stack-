defmodule MetadataAppWeb.FichaLiveRenglonesPreTest do
  @moduledoc """
  SPEC-SYS-0510202601 §2.4 (R8, R9, D5): el "Guardar" de la Ficha le pasa a
  la regla PRE del encabezado los renglones nuevos y quitados, aunque el
  encabezado no cambie. Escenario: MetadataApp.PedidoMultinivelFixtures y
  la regla de prueba test/support/reglas_pedido_prueba_multinivel.ex (que
  corre en el proceso del LiveView, así que aquí se verifica el mensaje en
  pantalla y lo que quedó en la base).
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures
  import MetadataApp.PedidoMultinivelFixtures

  alias MetadataApp.{Permissions, Repo}
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.MetaBusinessProcess.Catalogos.PedidoPruebaMultinivel

  setup %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa renglones pre #{System.unique_integer()}"}) |> Repo.insert()
    {:ok, _} = %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()
    rol = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

    registrar_metadata!()
    # Mismo efecto que "Conceder todos" en la pestaña Permisos del catálogo.
    Permissions.conceder_permisos_catalogo(rol.id, Enum.map(~w(leer crear editar alta guardar), &{maestro(), &1}))

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
    %{conn: conn}
  end

  defp guardar_con_renglones(conn, pedido, nuevas, eliminadas) do
    {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")
    render_hook(view, "grid_sync", %{"catalogo" => partidas(), "nuevas" => nuevas, "editadas" => [], "eliminadas" => eliminadas})
    view |> form("#form-ficha-datos") |> render_submit()
  end

  test "agregar solo una partida prohibida dispara la regla del encabezado y no guarda nada (R8, R9)", %{conn: conn} do
    pedido = pedido!("F-1", ["Tornillos"])

    html = guardar_con_renglones(conn, pedido, [%{producto() => "PROHIBIDO"}], [])

    assert html =~ "el pedido no puede llevar una partida PROHIBIDO"
    assert productos_en_base(pedido.id) == ["Tornillos"]
  end

  test "agregar solo una partida válida pasa por guardar y se guarda (D5)", %{conn: conn} do
    pedido = pedido!("F-2", ["Tornillos"])

    guardar_con_renglones(conn, pedido, [%{producto() => "Rondanas"}], [])

    assert productos_en_base(pedido.id) == ["Tornillos", "Rondanas"]
  end

  test "quitar la única partida de un pedido REQ- se rechaza y la partida sigue (R8, R9)", %{conn: conn} do
    pedido = pedido!("REQ-3", ["Tornillos"])

    html = guardar_con_renglones(conn, pedido, [], [1])

    assert html =~ "el pedido necesita al menos una partida"
    assert productos_en_base(pedido.id) == ["Tornillos"]
  end

  test "editar solo el encabezado sigue igual", %{conn: conn} do
    pedido = pedido!("F-4", ["Tornillos"])

    {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")
    render_change(view, "validar", %{"campos" => %{folio() => "F-4B"}})
    view |> form("#form-ficha-datos", %{"campos" => %{folio() => "F-4B"}}) |> render_submit()

    assert Repo.get!(PedidoPruebaMultinivel, pedido.id).pedido_prueba_multinivel_folio == "F-4B"
    assert productos_en_base(pedido.id) == ["Tornillos"]
  end
end
