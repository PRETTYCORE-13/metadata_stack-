defmodule MetadataAppWeb.FichaLivePostRenglonesTest do
  @moduledoc """
  SPEC-SYS-0710202602 (R1-R3, R6): el "Guardar" de la Ficha escribe los
  renglones nuevos y quitados dentro de la transición, antes de la regla
  POST del encabezado, y sin duplicarlos. Escenario:
  MetadataApp.PedidoMultinivelFixtures y la regla de prueba
  test/support/reglas_post_pedido_prueba_multinivel.ex (corre en el proceso
  del LiveView, así que aquí se verifica lo que quedó en la base).
  """
  # async: false -- registra la metadata de pedido_prueba_multinivel.
  use MetadataAppWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures
  import MetadataApp.PedidoMultinivelFixtures

  alias MetadataApp.{Permissions, Repo}
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.MetaBusinessProcess.Catalogos.PedidoPruebaMultinivel

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{}
      |> Empresa.changeset(%{nombre: "Empresa post renglones #{System.unique_integer()}"})
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

  defp guardar_con_renglones(conn, pedido, nuevas, eliminadas) do
    {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")

    render_hook(view, "grid_sync", %{
      "catalogo" => partidas(),
      "nuevas" => nuevas,
      "editadas" => [],
      "eliminadas" => eliminadas
    })

    view |> form("#form-ficha-datos") |> render_submit()
  end

  defp folio_en_base(pedido),
    do: Repo.get!(PedidoPruebaMultinivel, pedido.id).pedido_prueba_multinivel_folio

  test "agregar y quitar partidas: el POST ve y marca solo las definitivas, sin duplicar", %{
    conn: conn
  } do
    pedido = pedido!("POST-ESCRIBE", ["Tornillos", "Tuercas"])

    guardar_con_renglones(conn, pedido, [%{producto() => "Rondanas"}], [1])

    # La regla vio 2 partidas (Tuercas y Rondanas) y marcó cada una una vez
    # más; Tuercas ya traía la marca del alta.
    assert folio_en_base(pedido) == "POST-ESCRIBE (2)"
    assert productos_en_base(pedido.id) == ["Tuercas**", "Rondanas*"]
  end

  test "si el POST falla, no se crea ni se quita ninguna partida", %{conn: conn} do
    pedido = pedido!("F-POST", ["Tornillos"])

    {1, _} =
      Repo.update_all(from(p in PedidoPruebaMultinivel, where: p.id == ^pedido.id),
        set: [pedido_prueba_multinivel_folio: "POST-FALLA"]
      )

    html = guardar_con_renglones(conn, pedido, [%{producto() => "Rondanas"}], [1])

    assert html =~ "falla de prueba del POST"
    assert productos_en_base(pedido.id) == ["Tornillos"]
  end
end
