defmodule MetadataAppWeb.Sysadmin.CatalogoPermisosLiveTest do
  @moduledoc """
  Uso standalone de CatalogoPermisosLive ("Permission Sets",
  SPEC-SYS-1709202602) -- picker de catálogo de la izquierda +
  navegación por URL. La matriz de permisos en sí (misma LiveView,
  también embebida en BcMotorLive) ya está documentada en
  SPEC-SYS-1109202605-bc-motor-tab-permisos-alcance, no se re-testea
  acá. Foco: que elegir un catálogo o conceder un permiso NO vacíe el
  filtro del picker (R4/R4a-b, corregido 2026-09-17 -- `elegir_catalogo`
  sigue remontando con `push_navigate`, pero ahora lleva el texto
  buscado como query param `?q=`, que `mount/3` usa para restaurar el
  picker de una).
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaConsultas
  alias MetadataApp.Permissions

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{}
      |> Empresa.changeset(%{nombre: "Empresa permission sets test #{System.unique_integer()}"})
      |> Repo.insert()

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

  # Consulta Ecto (schema_context_type: 3) -- bypasea la exigencia de tener
  # una transición real, la forma más chica de armar un catálogo válido
  # para buscar_catalogos/2 sin montar un motor de estados completo. A
  # diferencia de permissions_test.exs (que solo llama buscar_catalogos/2
  # directo), acá la LiveView SÍ monta la pantalla completa -- necesita
  # también la fila MetaConsultas (mismo patrón que
  # catalogo_live_consulta_test.exs), si no cargar_matriz/1 revienta
  # tratando de resolver el catálogo base de una Consulta inexistente.
  defp catalogo_fixture(prefijo) do
    nombre = "#{prefijo}_#{System.unique_integer([:positive])}"

    {:ok, {header, _detalles}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Catálogo de prueba #{nombre}",
        "schema_context_nav" => "/catalogo_permisos_test_#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 3,
        "detalles" => []
      })

    {:ok, _consulta} = MetaConsultas.crear(header, "meta_fixture_cliente")

    header
  end

  test "elegir un catálogo del picker no vacía el texto ni los resultados buscados (R4a)", %{conn: conn} do
    prefijo = "pty_ch_test_#{System.unique_integer([:positive])}"
    c1 = catalogo_fixture(prefijo)
    _c2 = catalogo_fixture(prefijo)

    {:ok, view, _html} = live(conn, ~p"/sysadmin/catalogos/permisos")

    html = view |> element("input[phx-keyup=buscar_catalogo_picker]") |> render_keyup(%{"value" => prefijo})
    assert html =~ c1.schema_context_name

    resultado =
      view
      |> element(~s(button[phx-click=elegir_catalogo][phx-value-recurso="#{c1.schema_context_name}"]))
      |> render_click()

    {:ok, _view2, html} = follow_redirect(resultado, conn)
    assert html =~ ~s(value="#{prefijo}")
    assert html =~ c1.schema_context_name
  end

  test "conceder un permiso tampoco vacía el filtro del picker (R4a)", %{conn: conn, empresa: empresa} do
    prefijo = "pty_ch_test_#{System.unique_integer([:positive])}"
    catalogo = catalogo_fixture(prefijo)
    {:ok, rol} = Permissions.crear_rol(%{empresa_id: empresa.id, nombre: "Rol picker #{System.unique_integer()}"})

    {:ok, view, _html} = live(conn, ~p"/sysadmin/catalogos/#{catalogo.schema_context_name}/permisos")
    view |> element("input[phx-keyup=buscar_catalogo_picker]") |> render_keyup(%{"value" => prefijo})

    html =
      view
      |> element(~s(button[phx-click=toggle_permiso][phx-value-rol_id="#{rol.id}"][phx-value-accion="leer"]))
      |> render_click()

    assert html =~ ~s(value="#{prefijo}")
    assert Permissions.estado_permisos_para_roles(catalogo.schema_context_name, [rol.id], ["leer"])[{rol.id, "leer"}].concedido
  end

  test "recargar la página (nueva conexión) arranca con el picker vacío (R4b)", %{conn: conn} do
    catalogo = catalogo_fixture("pty_ch_reload_test")
    {:ok, _view, html} = live(conn, ~p"/sysadmin/catalogos/#{catalogo.schema_context_name}/permisos")

    refute html =~ ~s(value="pty_ch")
  end

  # Bug real encontrado en vivo (2026-09-17, navegando con el comodín "*"):
  # un header es_consulta:true sin fila meta_schema_consulta (huérfano --
  # se abandonó a mitad de crear, o se borró la Consulta sin borrar el
  # header) tumbaba la pantalla entera con KeyError. Este test arma ese
  # mismo estado a propósito: header tipo 3 SIN llamar MetaConsultas.crear/2
  # (a diferencia de catalogo_fixture/1, que siempre crea ambos).
  test "una Consulta huérfana (sin fila meta_schema_consulta) no revienta la pantalla", %{conn: conn} do
    nombre = "consulta_huerfana_test_#{System.unique_integer([:positive])}"

    {:ok, {header, _detalles}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Consulta huérfana de prueba",
        "schema_context_nav" => "/consulta_huerfana_test_#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 3,
        "detalles" => []
      })

    assert {:ok, _view, html} = live(conn, ~p"/sysadmin/catalogos/#{header.schema_context_name}/permisos")
    assert html =~ "no tiene su configuración armada"
  end

  describe "lista completa con el buscador vacío (SPEC-SYS-0910202601)" do
    test "sin escribir nada ya aparecen los catálogos permisibles", %{conn: conn} do
      catalogo = catalogo_fixture("pty_lista_test")

      {:ok, view, _html} = live(conn, ~p"/sysadmin/catalogos/permisos")

      assert has_element?(view, "#lista-catalogos-picker #picker-#{catalogo.schema_context_name}")
    end

    test "clic en uno de la lista navega a sus permisos y lo resalta", %{conn: conn} do
      catalogo = catalogo_fixture("pty_lista_test")

      {:ok, view, _html} = live(conn, ~p"/sysadmin/catalogos/permisos")

      {:ok, view2, html} =
        view
        |> element(~s(button[phx-click=elegir_catalogo][phx-value-recurso="#{catalogo.schema_context_name}"]))
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ catalogo.schema_context_label
      assert has_element?(view2, "#picker-#{catalogo.schema_context_name} button.bg-yellow-100")
    end

    test "escribir filtra la lista y borrar el texto la regresa completa", %{conn: conn} do
      buscado = catalogo_fixture("pty_lista_buscado")
      otro = catalogo_fixture("pty_lista_otro")

      {:ok, view, _html} = live(conn, ~p"/sysadmin/catalogos/permisos")
      input = element(view, "input[phx-keyup=buscar_catalogo_picker]")

      render_keyup(input, %{"value" => buscado.schema_context_name})
      assert has_element?(view, "#picker-#{buscado.schema_context_name}")
      refute has_element?(view, "#picker-#{otro.schema_context_name}")

      render_keyup(input, %{"value" => ""})
      assert has_element?(view, "#picker-#{otro.schema_context_name}")
    end
  end

  describe "filtro por módulo (SPEC-SYS-0910202601 R6-R9)" do
    # R6a: el módulo sale de los dos primeros segmentos del nombre técnico
    # ("pty_mx12_areas" -> "pty-mx12"); cada test usa un módulo único.
    defp modulo_unico, do: "mx#{System.unique_integer([:positive])}"

    test "lista los módulos con su conteo; elegir uno deja solo sus catálogos y Todos regresa todo", %{conn: conn} do
      modulo = modulo_unico()
      adentro_1 = catalogo_fixture("pty_#{modulo}_areas")
      adentro_2 = catalogo_fixture("pty_#{modulo}_empleados")
      afuera = catalogo_fixture("pty_#{modulo_unico()}_otro")

      {:ok, view, _html} = live(conn, ~p"/sysadmin/catalogos/permisos")
      assert view |> element("#filtro-modulo option[value='pty-#{modulo}']") |> render() =~ "pty-#{modulo} (2)"

      view |> form("#filtro-modulo-form", %{"modulo" => "pty-#{modulo}"}) |> render_change()
      assert has_element?(view, "#picker-#{adentro_1.schema_context_name}")
      assert has_element?(view, "#picker-#{adentro_2.schema_context_name}")
      refute has_element?(view, "#picker-#{afuera.schema_context_name}")

      view |> form("#filtro-modulo-form", %{"modulo" => ""}) |> render_change()
      assert has_element?(view, "#picker-#{afuera.schema_context_name}")
    end

    test "módulo y texto del buscador se aplican juntos (R8)", %{conn: conn} do
      modulo = modulo_unico()
      buscado = catalogo_fixture("pty_#{modulo}_buscado")
      otro = catalogo_fixture("pty_#{modulo}_otro")

      {:ok, view, _html} = live(conn, ~p"/sysadmin/catalogos/permisos")
      view |> form("#filtro-modulo-form", %{"modulo" => "pty-#{modulo}"}) |> render_change()
      view |> element("input[phx-keyup=buscar_catalogo_picker]") |> render_keyup(%{"value" => "buscado"})

      assert has_element?(view, "#picker-#{buscado.schema_context_name}")
      refute has_element?(view, "#picker-#{otro.schema_context_name}")
    end

    test "elegir un catálogo conserva el módulo elegido (R9)", %{conn: conn} do
      modulo = modulo_unico()
      adentro = catalogo_fixture("pty_#{modulo}_conserva")
      afuera = catalogo_fixture("pty_#{modulo_unico()}_fuera")

      {:ok, view, _html} = live(conn, ~p"/sysadmin/catalogos/permisos")
      view |> form("#filtro-modulo-form", %{"modulo" => "pty-#{modulo}"}) |> render_change()

      {:ok, view2, _html} =
        view
        |> element(~s(button[phx-click=elegir_catalogo][phx-value-recurso="#{adentro.schema_context_name}"]))
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(view2, "#filtro-modulo option[value='pty-#{modulo}'][selected]")
      refute has_element?(view2, "#picker-#{afuera.schema_context_name}")
    end
  end
end
