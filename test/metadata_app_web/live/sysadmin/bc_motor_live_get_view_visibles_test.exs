defmodule MetadataAppWeb.Sysadmin.BcMotorLiveGetViewVisiblesTest do
  @moduledoc """
  Casillas "Vis." de "Columnas del GET" en la Lista del BC Motor
  (SPEC-SYS-1109202606, R4/R20): lo marcado sin guardar sobrevive a
  reordenar por arrastre y a los controles de la fila que guardan al
  instante, y solo "Guardar columnas" lo persiste.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @catalogo "meta_fixture_cliente"
  @nombre "meta_fixture_cliente_nombre"
  @edad "meta_fixture_cliente_edad"

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa motor visibles #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    for campo <- [@nombre, @edad], do: fijar_visible(campo, true)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn}
  end

  defp detalle(campo), do: @catalogo |> MetaSchemaContext.listar_detalles() |> Enum.find(&(&1.schema_context_field == campo))

  defp visible_en_base?(campo), do: detalle(campo).schema_context_properties["visible"] == true

  defp fijar_visible(campo, valor) do
    d = detalle(campo)
    {:ok, _} = MetaSchemaContext.actualizar_detalle(d, %{"schema_context_properties" => Map.put(d.schema_context_properties, "visible", valor)})
  end

  defp marcada?(view, clave), do: has_element?(view, "#getview-visible-#{clave}[checked]")

  # El navegador manda "value" en el phx-click de un checkbox solo si quedó
  # marcado; el cliente de pruebas siempre lo mandaría, por eso el payload
  # se arma a mano.
  defp clic(view, clave, marcada?) do
    payload = if marcada?, do: %{"clave" => clave, "value" => clave}, else: %{"clave" => clave}
    render_click(view, "marcar_visible_get_view", payload)
  end

  defp abrir(conn) do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{@catalogo}/motor")
    view
  end

  test "desmarcar y luego reordenar conserva la casilla sin tocar la base", %{conn: conn} do
    view = abrir(conn)
    assert marcada?(view, @nombre)

    clic(view, @nombre, false)
    refute marcada?(view, @nombre)

    view
    |> element("#tabla-get-view-ordenable")
    |> render_hook("mover_a", %{"id" => @nombre, "index" => 0, "contenedor_id" => "columnas-get-view"})

    refute marcada?(view, @nombre)
    assert marcada?(view, @edad)
    assert visible_en_base?(@nombre)

    clic(view, @nombre, true)
    assert marcada?(view, @nombre)
  end

  test "clics rápidos: siempre gana el último valor real de la casilla", %{conn: conn} do
    view = abrir(conn)

    # Dos eventos seguidos con el mismo valor (el navegador cambió la casilla
    # entre dos clics sin que el server alcanzara a repintar): invertir
    # dejaría la casilla al revés de lo que ve el usuario.
    clic(view, @nombre, false)
    clic(view, @nombre, false)
    refute marcada?(view, @nombre)

    for valor <- [true, false, true], do: clic(view, @nombre, valor)
    assert marcada?(view, @nombre)
  end

  test "un control de la fila que guarda al instante no regresa las casillas", %{conn: conn} do
    view = abrir(conn)

    clic(view, @nombre, false)
    render_click(view, "cambiar_acotado", %{"campo" => "#{@catalogo}::#{@edad}"})

    refute marcada?(view, @nombre)
    assert visible_en_base?(@nombre)
  end

  test "deseleccionar todos y guardar persiste lo pendiente", %{conn: conn} do
    view = abrir(conn)

    view |> element("#get-view-deseleccionar-todos") |> render_click()
    refute marcada?(view, @nombre)
    refute marcada?(view, @edad)
    refute marcada?(view, "id")

    view |> element("#get-view-seleccionar-todos") |> render_click()
    clic(view, @edad, false)
    view |> element("#get-view-form") |> render_submit()

    assert visible_en_base?(@nombre)
    refute visible_en_base?(@edad)

    # Sin pendientes después de guardar: un reordenamiento pinta lo guardado.
    view
    |> element("#tabla-get-view-ordenable")
    |> render_hook("mover_a", %{"id" => @edad, "index" => 0, "contenedor_id" => "columnas-get-view"})

    assert marcada?(view, @nombre)
    refute marcada?(view, @edad)
  end
end
