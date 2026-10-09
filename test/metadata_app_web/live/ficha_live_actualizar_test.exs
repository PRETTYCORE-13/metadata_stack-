defmodule MetadataAppWeb.FichaLiveActualizarTest do
  @moduledoc """
  "Actualizar ficha" relee el registro y descarta los renglones en staging;
  la tabla tiene que recargarse con los persistidos para no mostrar cambios
  que "Guardar" ya no tiene. Y "Guardar" sin cambios avisa en vez de no
  hacer nada en silencio. Escenario: MetadataApp.PedidoMultinivelFixtures.
  """
  # async: false -- registra la metadata de pedido_prueba_multinivel.
  use MetadataAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures
  import MetadataApp.PedidoMultinivelFixtures

  alias MetadataApp.{Permissions, Repo}
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{}
      |> Empresa.changeset(%{nombre: "Empresa actualizar #{System.unique_integer()}"})
      |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{}
      |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id})
      |> Repo.insert()

    rol = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

    registrar_metadata!()

    Permissions.conceder_permisos_catalogo(
      rol.id,
      Enum.map(~w(leer crear editar alta guardar), &{maestro(), &1})
    )

    conn =
      conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn}
  end

  test "Actualizar ficha recarga la tabla y descarta la partida editada", %{conn: conn} do
    pedido = pedido!("ACTUALIZAR", ["Tornillos"])
    {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")

    render_hook(view, "grid_sync", %{
      "catalogo" => partidas(),
      "nuevas" => [],
      "editadas" => [%{"renglon_id" => 1, "campos" => %{producto() => "Tuercas"}}],
      "eliminadas" => []
    })

    render_hook(view, "actualizar_ficha", %{})

    catalogo = partidas()
    assert_push_event(view, "grid_recargar", %{catalogo: ^catalogo, filas: [_]})

    html = view |> form("#form-ficha-datos") |> render_submit()

    assert html =~ "No hay cambios por guardar."
    assert productos_en_base(pedido.id) == ["Tornillos"]
  end
end
