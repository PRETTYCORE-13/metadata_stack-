defmodule MetadataAppWeb.FichaLiveColumnasSoloLecturaTest do
  @moduledoc """
  SPEC-SYS-0810202602: los campos visibles no editables de un detalle se
  muestran en la tabla de renglones como columnas de solo lectura, nunca
  en el formulario de captura ni en lo que se guarda. Escenario:
  MetadataApp.PedidoMultinivelFixtures con el producto de la partida
  marcado `editable: false` (hace las veces de un campo calculado).
  """
  # async: false -- registra la metadata de pedido_prueba_multinivel.
  use MetadataAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures
  import MetadataApp.PedidoMultinivelFixtures

  alias MetadataApp.{Permissions, Repo}
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{}
      |> Empresa.changeset(%{nombre: "Empresa solo lectura #{System.unique_integer()}"})
      |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{}
      |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id})
      |> Repo.insert()

    rol = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

    registrar_metadata!()
    Permissions.conceder_permisos_catalogo(rol.id, Enum.map(~w(leer crear editar alta guardar), &{maestro(), &1}))

    pedido = pedido!("SOLO-LECTURA", ["Tornillos"])

    [det] = MetaSchemaContext.listar_detalles(partidas()) |> Enum.filter(&(&1.schema_context_field == producto()))

    {:ok, _} =
      MetaSchemaContext.actualizar_detalle(det, %{
        "schema_context_properties" => Map.put(det.schema_context_properties, "editable", false)
      })

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
    %{conn: conn, pedido: pedido}
  end

  defp columnas_del_grid(view) do
    view
    |> element("#grid-#{partidas()}")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-columnas")
    |> List.first()
    |> Jason.decode!()
  end

  test "la columna calculada aparece de solo lectura; fecha_registro no", %{conn: conn, pedido: pedido} do
    {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")
    render_click(view, "cambiar_tab", %{"tab" => "detalle"})

    columnas = columnas_del_grid(view)

    assert [%{"solo_lectura" => true, "decimales" => 2}] = Enum.filter(columnas, &(&1["campo"] == producto()))
    refute Enum.any?(columnas, &(&1["campo"] == "fecha_registro"))
  end

  test "el formulario de captura no la incluye", %{conn: conn, pedido: pedido} do
    {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")
    render_click(view, "cambiar_tab", %{"tab" => "detalle"})
    render_hook(view, "detalle_nueva_linea", %{"catalogo" => partidas()})

    assert has_element?(view, "#renglon-form-#{partidas()}")
    refute has_element?(view, ~s(#renglon-form-#{partidas()} [name="renglon[#{producto()}]"]))
  end

  test "una columna de solo lectura que llega en grid_sync no se guarda", %{conn: conn, pedido: pedido} do
    {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")

    render_hook(view, "grid_sync", %{
      "catalogo" => partidas(),
      "nuevas" => [%{producto() => "Rondanas"}],
      "editadas" => [%{"renglon_id" => 1, "campos" => %{producto() => "Tuercas"}}],
      "eliminadas" => []
    })

    html = view |> form("#form-ficha-datos") |> render_submit()

    assert html =~ "No hay cambios por guardar."
    assert productos_en_base(pedido.id) == ["Tornillos"]
  end
end
