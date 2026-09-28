defmodule MetadataAppWeb.Sysadmin.BcListLiveListosTest do
  # SPEC-SYS-2809202601 §8 (R20-R25): la revisión "¿listo para
  # publicarse?" corre en segundo plano y no se repite al buscar.
  #
  # Un catálogo que de verdad pase MetaEstadosAdmin.puede_desplegar?/1
  # necesita autómata + reglas compiladas + .ex generado (DDL), que deja
  # residuo fuera del Sandbox -- mismo criterio que bc_list_live_test.exs
  # para "Copiar". Por eso el caso "listo" se prueba sobre el componente
  # filas_arbol/1 y el de falla llamando handle_async/3 directo; el
  # LiveView completo se prueba con catálogos que NO están listos.
  #
  # async: false a propósito: BC Lista escucha el PubSub global
  # ("bc_contextos") y relanza la revisión con cada {:bc_creado, _} o
  # {:bc_actualizado, _}. Un test asíncrono de otro módulo que crea un
  # catálogo en paralelo haría reaparecer el indicador justo después de
  # render_async/2 (falla real en CI, 2026-09-28).
  use MetadataAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataAppWeb.Sysadmin.BcListLive

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa bc listos test #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn}
  end

  defp unique, do: System.unique_integer([:positive])

  # Nav de 2 segmentos: la fila queda como hoja directa de la carpeta
  # "pruebas_listos" (ver el comentario de header_leaf/3 en
  # bc_list_live_test.exs).
  defp header_leaf(nombre, maestro_id \\ nil) do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => nombre,
        "schema_context_nav" => "/pruebas_listos/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "schema_encabezado_id" => maestro_id,
        "detalles" => []
      })

    header
  end

  defp abrir_carpeta(view) do
    view |> element("button[phx-click=toggle_carpeta][phx-value-ruta=pruebas_listos]") |> render_click()
  end

  defp casilla?(html, nombre) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("input[phx-click=toggle_seleccion][phx-value-tabla=#{nombre}]")
    |> Enum.count() == 1
  end

  defp socket_con(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
  end

  describe "revisión en segundo plano (R20, R21)" do
    test "el render estático no revisa: muestra el indicador y ninguna casilla", %{conn: conn} do
      nombre = "bclistos_incompleto_#{unique()}"
      header_leaf(nombre)

      html = conn |> get(~p"/sysadmin/bc-list") |> html_response(200)

      assert html =~ ~s(id="revisando-listos")
      refute html =~ ~s(phx-click="toggle_seleccion")
    end

    test "al terminar la revisión se quita el indicador y un catálogo incompleto no lleva casilla", %{conn: conn} do
      nombre = "bclistos_incompleto_#{unique()}"
      header_leaf(nombre)

      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
      render_async(view, 5_000)
      abrir_carpeta(view)

      refute has_element?(view, "#revisando-listos")
      refute has_element?(view, "#aviso-revision-listos")
      assert has_element?(view, "td", nombre)
      refute has_element?(view, "input[phx-click=toggle_seleccion][phx-value-tabla=#{nombre}]")
    end
  end

  describe "casilla de Publicar paquete (R16)" do
    setup do
      maestro = header_leaf("bclistos_maestro_#{unique()}")
      detalle = header_leaf("bclistos_detalle_#{unique()}", maestro.id)
      otro = header_leaf("bclistos_otro_#{unique()}")

      nodos =
        [maestro, detalle, otro]
        |> Enum.map(&MetaSchemaContext.item_de_header/1)
        |> MetaSchemaContext.construir_arbol()

      %{maestro: maestro, detalle: detalle, otro: otro, nodos: nodos}
    end

    test "aparece solo en los catálogos que la revisión marcó como listos", ctx do
      html =
        render_component(&BcListLive.filas_arbol/1,
          nodos: ctx.nodos,
          carpetas_expandidas: MapSet.new(["pruebas_listos"]),
          listos: %{ctx.maestro.schema_context_name => true, ctx.otro.schema_context_name => false}
        )

      assert casilla?(html, ctx.maestro.schema_context_name)
      refute casilla?(html, ctx.otro.schema_context_name)
      refute casilla?(html, ctx.detalle.schema_context_name)
    end
  end

  describe "cuándo NO se vuelve a revisar (R22)" do
    test "buscar no relanza la revisión", %{conn: conn} do
      nombre = "bclistos_busqueda_#{unique()}"
      header_leaf(nombre)

      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
      render_async(view, 5_000)
      refute has_element?(view, "#revisando-listos")

      # revisar_listos/1 pone :pendiente de forma síncrona en el mismo
      # evento; si buscar lo relanzara, el indicador volvería a aparecer
      # en este mismo render.
      view |> element("input[phx-keyup=buscar]") |> render_keyup(%{"value" => "bclistos"})

      refute has_element?(view, "#revisando-listos")
    end
  end

  describe "resultado de la revisión (handle_async)" do
    test "con éxito guarda el resultado y quita de la selección lo que ya no está listo" do
      socket = socket_con(%{seleccionados: MapSet.new(["a", "b"]), listos: %{}, revision_listos: :pendiente})

      {:noreply, socket} = BcListLive.handle_async(:revisar_listos, {:ok, %{"a" => true, "b" => false}}, socket)

      assert socket.assigns.listos == %{"a" => true, "b" => false}
      assert socket.assigns.revision_listos == :ok
      assert socket.assigns.seleccionados == MapSet.new(["a"])
    end

    test "si falla deja la tabla sin casillas, marca el error y lo registra (R25)" do
      socket = socket_con(%{seleccionados: MapSet.new(["a"]), listos: %{"a" => true}, revision_listos: :pendiente})

      log =
        capture_log(fn ->
          {:noreply, socket} = BcListLive.handle_async(:revisar_listos, {:exit, :boom}, socket)
          send(self(), {:socket, socket})
        end)

      assert_received {:socket, socket}
      assert socket.assigns.listos == %{}
      assert socket.assigns.revision_listos == :error
      assert socket.assigns.seleccionados == MapSet.new()
      assert log =~ "no se pudo revisar"
    end
  end

  describe "volver a confirmar al publicar (R24)" do
    test "un catálogo marcado que ya no está listo se quita con aviso y el modal no se abre", %{conn: conn} do
      nombre = "bclistos_ya_no_#{unique()}"
      header_leaf(nombre)

      {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list")
      render_async(view, 5_000)

      # Simula una selección hecha cuando todavía estaba listo (la casilla
      # ya no se pinta para él, así que se manda el evento directo).
      render_click(view, "toggle_seleccion", %{"tabla" => nombre})
      html = render_click(view, "abrir_wizard_publicar", %{})

      assert html =~ "Ya no están listos para publicarse"
      assert html =~ nombre
      refute has_element?(view, "h2", "Publicar paquete")
      refute has_element?(view, "button[phx-click=abrir_wizard_publicar]")
    end
  end
end
