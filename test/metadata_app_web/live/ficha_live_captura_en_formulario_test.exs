defmodule MetadataAppWeb.FichaLiveCapturaEnFormularioTest do
  @moduledoc """
  SPEC-SYS-1109202607 §6d (R21-R27, R21a): el componente "Renglones de
  detalle" en modo Captura pinta la captura de renglones dentro del
  formulario, solo para un detalle del maestro, una vez por detalle, y ese
  detalle sale del tab "Detalle". Escenario: MetadataApp.PedidoMultinivelFixtures.
  """
  # async: false -- registra la metadata de pedido_prueba_multinivel.
  use MetadataAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures
  import MetadataApp.PedidoMultinivelFixtures

  alias MetadataApp.{MetaPlantillas, Permissions, Repo}
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}

  setup %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa captura #{System.unique_integer()}"}) |> Repo.insert()
    {:ok, _} = %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()
    rol = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

    maestro = registrar_metadata!()
    Permissions.conceder_permisos_catalogo(rol.id, Enum.map(~w(leer crear editar alta guardar), &{maestro(), &1}))

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
    %{conn: conn, maestro: maestro}
  end

  defp nodo_renglones(modo) do
    MetaPlantillas.nuevo_nodo("renglones")
    |> put_in(["propiedades", "catalogo"], partidas())
    |> put_in(["propiedades", "modo"], modo)
  end

  defp publicar_plantilla!(maestro, nodo) do
    raiz = %{"tipo" => "raiz", "propiedades" => %{"filas" => 1, "columnas" => 1, "gap" => "normal"}, "hijos" => []}
    {:ok, definicion} = MetaPlantillas.colocar_en_celda(raiz, nil, nodo, 0, 0)
    {:ok, plantilla} = MetaPlantillas.crear_plantilla(maestro.id, %{"nombre" => "Captura", "estado" => "borrador", "definicion" => definicion})
    {:ok, _} = MetaPlantillas.publicar_plantilla(plantilla)
  end

  describe "Constructor (R21a, R24)" do
    test "acepta Captura para un detalle del maestro y rechaza repetirla", %{conn: conn} do
      {:ok, view, _} = live(conn, "/sysadmin/bc-list/#{maestro()}/plantilla")
      render_click(view, "nueva_plantilla", %{})

      render_click(view, "seleccionar_celda", %{"fila" => "0", "columna" => "0"})
      render_click(view, "grid_colocar_tipo", %{"tipo" => "renglones"})
      render_change(view, "actualizar_propiedad", %{"catalogo" => partidas(), "modo" => "captura"})
      assert has_element?(view, "#renglones-modo option[value=captura][selected]")

      render_click(view, "seleccionar_celda", %{"fila" => "1", "columna" => "0"})
      render_click(view, "grid_colocar_tipo", %{"tipo" => "renglones"})
      html = render_change(view, "actualizar_propiedad", %{"catalogo" => partidas(), "modo" => "captura"})
      assert html =~ "Ese detalle ya se captura en otro lugar de este formulario."
    end
  end

  describe "Ficha (R22, R23, R25, R26)" do
    test "la captura vive en el formulario, el tab Detalle desaparece y guarda", %{conn: conn, maestro: maestro} do
      publicar_plantilla!(maestro, nodo_renglones("captura"))
      pedido = pedido!("CAPTURA", ["Tornillos"])
      {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")

      assert has_element?(view, "#form-ficha-datos #grid-#{partidas()}")
      refute has_element?(view, "button[phx-value-tab=detalle]")

      render_hook(view, "detalle_nueva_linea", %{"catalogo" => partidas()})
      render_hook(view, "detalle_seleccionar_fila", %{"catalogo" => partidas(), "client_id" => "c1", "renglon_id" => nil, "valores" => %{}})

      assert has_element?(view, "#form-ficha-datos div#renglon-form-#{partidas()}")

      render_change(view, "validar", %{
        "_target" => ["renglones", partidas(), producto()],
        "renglones" => %{partidas() => %{producto() => "Rondanas"}},
        "campos" => %{}
      })

      catalogo = partidas()
      assert_push_event(view, "grid_actualizar_fila", %{catalogo: ^catalogo, client_id: "c1", valores: %{}} = evento)
      assert evento.valores[producto()] == "Rondanas"

      render_hook(view, "grid_sync", %{"catalogo" => partidas(), "nuevas" => [%{producto() => "Rondanas"}], "editadas" => [], "eliminadas" => []})
      view |> form("#form-ficha-datos") |> render_submit()

      assert productos_en_base(pedido.id) == ["Tornillos", "Rondanas"]
    end

    test "cambiar a otro tab de la Ficha no desmonta la captura (R25)", %{conn: conn, maestro: maestro} do
      publicar_plantilla!(maestro, nodo_renglones("captura"))
      pedido = pedido!("MONTADO", ["Tornillos"])
      {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")

      render_click(view, "cambiar_tab", %{"tab" => "historial"})
      assert has_element?(view, "#form-ficha-datos[hidden] #grid-#{partidas()}")
    end

    test "en Solo lectura todo sigue como hoy (R26)", %{conn: conn, maestro: maestro} do
      publicar_plantilla!(maestro, nodo_renglones("lectura"))
      pedido = pedido!("LECTURA", ["Tornillos"])
      {:ok, view, _} = live(conn, "/registro/#{maestro()}/#{pedido.id}")

      refute has_element?(view, "#form-ficha-datos #grid-#{partidas()}")
      assert has_element?(view, "button[phx-value-tab=detalle]")
    end
  end
end
