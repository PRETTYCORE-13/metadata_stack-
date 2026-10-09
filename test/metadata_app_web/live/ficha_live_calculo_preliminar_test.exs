defmodule MetadataAppWeb.FichaLiveCalculoPreliminarTest do
  @moduledoc """
  SPEC-SYS-0810202603: al cambiar un renglón en el formulario de captura, la
  Ficha pregunta a `calcular_renglon/3` del POST del maestro y manda a la
  tabla solo las columnas de solo lectura. Escenario:
  MetadataApp.PedidoMultinivelFixtures, su POST de prueba
  (test/support/reglas_post_pedido_prueba_multinivel.ex) y `insert_guid`
  de las partidas como columna de solo lectura.
  """
  # async: false -- registra la metadata de pedido_prueba_multinivel.
  use MetadataAppWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures
  import MetadataApp.PedidoMultinivelFixtures

  alias MetadataApp.{Permissions, Repo}
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaStateEngine.Reglas

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa preliminar #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

    registrar_metadata!()
    Permissions.conceder_permisos_catalogo(rol.id, Enum.map(~w(leer crear editar alta guardar), &{maestro(), &1}))

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
    %{conn: conn, pedido: pedido!("FOLIO-P", ["Tornillos"])}
  end

  defp con_columna_solo_lectura! do
    header = MetaSchemaContext.obtener_header_por_nombre(partidas())

    {:ok, _} =
      MetaSchemaContext.agregar_detalle(header, %{
        "schema_context_field" => "insert_guid",
        "schema_context_properties" => %{
          "etiqueta" => "Calculado",
          "tipo" => "string",
          "orden" => 2,
          "visible" => true,
          "editable" => false,
          "opcional" => true
        }
      })
  end

  defp cambiar_producto(view, producto) do
    render_hook(view, "detalle_nueva_linea", %{"catalogo" => partidas()})

    render_hook(view, "detalle_seleccionar_fila", %{
      "catalogo" => partidas(),
      "client_id" => "c1",
      "renglon_id" => nil,
      "valores" => %{}
    })

    render_hook(view, "detalle_form_cambiar", %{"catalogo" => partidas(), "renglon" => %{producto() => producto}})
  end

  describe "Reglas.calcular_renglon/4" do
    test "un catálogo sin la función no aplica" do
      assert Reglas.calcular_renglon("meta_fixture_cliente", "x", %{}, %{}) == :no_aplica
    end

    test "una excepción de la regla no aplica y queda en el log" do
      log =
        capture_log(fn ->
          assert Reglas.calcular_renglon(maestro(), partidas(), %{}, %{producto() => "BOOM"}) == :no_aplica
        end)

      assert log =~ "falla de prueba del cálculo"
    end
  end

  test "el cálculo llega a la tabla solo con columnas de solo lectura", %{conn: conn, pedido: pedido} do
    con_columna_solo_lectura!()
    {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")

    cambiar_producto(view, "CALC-1")

    catalogo = partidas()
    assert_push_event(view, "grid_calculado_fila", %{catalogo: ^catalogo, client_id: "c1", valores: valores}, 1000)
    assert valores == %{"insert_guid" => "CALC-1/FOLIO-P"}
  end

  test "un aviso se muestra en el formulario y vacía las columnas", %{conn: conn, pedido: pedido} do
    con_columna_solo_lectura!()
    {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")

    cambiar_producto(view, "AVISO-1")

    assert_push_event(view, "grid_calculado_fila", %{valores: %{"insert_guid" => ""}}, 1000)
    assert view |> element("#aviso-calculo-#{partidas()}") |> render() =~ "sin precio de prueba"
  end

  test "sin columnas de solo lectura no se pregunta", %{conn: conn, pedido: pedido} do
    {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")

    cambiar_producto(view, "CALC-1")

    refute_push_event(view, "grid_calculado_fila", %{}, 500)
  end
end
