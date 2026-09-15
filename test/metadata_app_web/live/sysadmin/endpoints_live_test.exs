defmodule MetadataAppWeb.Sysadmin.EndpointsLiveTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaConsultas
  alias MetadataApp.ConsultaEndpoints
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente

  defp unique, do: System.unique_integer([:positive])
  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa endpoints live #{unique()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn, empresa: empresa}
  end

  test ":index está vacío antes de crear ningún endpoint", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sysadmin/endpoints")
    assert html =~ "Todavía no creaste ningún endpoint."
  end

  test ":nuevo -- elegir catálogo base sin detalle crea la Consulta oculta + un endpoint en borrador, y aterriza en :editar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/endpoints/nuevo")

    # El <select> de "Tabla detalle" solo aparece en el DOM una vez
    # elegido el catálogo base (:if={@catalogo_base}) -- primero el
    # phx-change que lo revela, recién después se puede armar el
    # form completo para el submit.
    view |> form("form[phx-submit=crear_endpoint]", %{"catalogo_base" => "meta_fixture_cliente"}) |> render_change()

    assert {:error, {:live_redirect, %{to: path}}} =
             view
             |> form("form[phx-submit=crear_endpoint]", %{"catalogo_base" => "meta_fixture_cliente", "catalogo_detalle" => ""})
             |> render_submit()

    assert path =~ ~r{^/sysadmin/endpoints/endpoint_meta_fixture_cliente_\d+$}

    [_, nombre] = Regex.run(~r{^/sysadmin/endpoints/(.+)$}, path)
    header = MetaSchemaContext.obtener_header_por_nombre(nombre)
    assert header.schema_context_type == 3
    assert header.schema_visible == false

    consulta = MetaConsultas.obtener_por_header_id(header.id)
    assert consulta.catalogo_base == "meta_fixture_cliente"

    endpoint = ConsultaEndpoints.obtener_por_consulta(consulta.id)
    assert endpoint
    assert endpoint.estado == "borrador"

    {:ok, _view2, html2} = live(conn, path)
    assert html2 =~ "Configuración del endpoint"
    assert html2 =~ "Campos"

    # También tiene que aparecer en :index de inmediato -- sin depender
    # de que el admin llegue a tocar "Guardar" en :editar (evita el
    # mismo problema de endpoints huérfanos que motivó tener Eliminar).
    {:ok, _view3, html3} = live(conn, ~p"/sysadmin/endpoints")
    assert html3 =~ endpoint.nombre
  end

  test ":nuevo -- tabla detalle sin relación detectable muestra el error en vez de crear nada", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sysadmin/endpoints/nuevo")

    view |> form("form[phx-submit=crear_endpoint]", %{"catalogo_base" => "meta_fixture_cliente"}) |> render_change()

    html =
      view
      |> form("form[phx-submit=crear_endpoint]", %{
        "catalogo_base" => "meta_fixture_cliente",
        "catalogo_detalle" => "meta_fixture_equipo"
      })
      |> render_submit()

    assert html =~ "No se pudo detectar automáticamente la relación"
    assert ConsultaEndpoints.listar_todos() == []
  end

  defp criar_endpoint_borrador do
    nombre = "endpoint_meta_fixture_cliente_#{unique()}"

    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Endpoint — Cliente",
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => false,
        "schema_context_type" => 3,
        "detalles" => []
      })

    {:ok, _consulta} = MetaConsultas.crear(header, "meta_fixture_cliente")
    header
  end

  test ":editar -- marcar Parámetro en Campos, Guardar, Probar, Publicar, Credenciales, Eliminar", %{conn: conn} do
    header = criar_endpoint_borrador()

    nombre_buscado = "endpoint_ui_#{unique()}"

    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(%{
      meta_fixture_cliente_nombre: nombre_buscado,
      meta_fixture_cliente_edad: 25,
      meta_fixture_cliente_venta: Decimal.new("10.00")
    })
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()

    {:ok, view, _html} = live(conn, ~p"/sysadmin/endpoints/#{header.schema_context_name}")

    render_click(view, "cambiar_es_parametro", %{"campo" => "meta_fixture_cliente::meta_fixture_cliente_nombre"})
    html = render(view)
    assert html =~ "meta_fixture_cliente__meta_fixture_cliente_nombre"

    clave = "meta_fixture_cliente__meta_fixture_cliente_nombre"
    ruta = "clientes-ui-#{unique()}"

    html_guardado =
      view
      |> form("form[phx-submit=guardar_endpoint]", %{
        "nombre" => "Clientes",
        "metodo" => "get",
        "ruta" => ruta,
        "descripcion" => "de prueba",
        "parametros_activos" => [clave],
        "obligatorios" => [clave],
        "descripciones" => %{clave => "Nombre del cliente a buscar."}
      })
      |> render_submit()

    assert html_guardado =~ "Endpoint guardado."
    assert html_guardado =~ "Ejemplo de solicitud"
    assert html_guardado =~ "GET /api/consultas/#{ruta}"
    # R52-R53 -- la descripción propia del parámetro se persiste y se
    # ve en la sección Documentación.
    assert html_guardado =~ "Nombre del cliente a buscar."

    html_prueba =
      view
      |> form("form[phx-submit=probar_endpoint]", %{"valores_prueba" => %{clave => nombre_buscado}})
      |> render_submit()

    assert html_prueba =~ nombre_buscado

    html_publicado = render_click(view, "publicar_endpoint", %{})
    assert html_publicado =~ "PUBLICADO"
    assert html_publicado =~ "/api/consultas/#{ruta}"

    render_click(view, "abrir_modal_nueva_credencial", %{})

    html_credencial =
      view
      |> form("form[phx-submit=crear_credencial]", %{"nombre" => "ERP", "campos_permitidos" => [clave]})
      |> render_submit()

    assert html_credencial =~ "Copiá esta API key ahora"
    [_, key_mostrada] = Regex.run(~r/block break-all">([^<]+)<\/code>/, html_credencial)

    {:ok, view2, _html_recargado} = live(conn, ~p"/sysadmin/endpoints/#{header.schema_context_name}")
    html_recargado = render(view2)
    refute html_recargado =~ key_mostrada
    assert html_recargado =~ "••••••••••••••••"

    assert {:error, {:live_redirect, %{to: "/sysadmin/endpoints"}}} =
             render_click(view2, "eliminar_endpoint_actual", %{})

    refute MetaSchemaContext.obtener_header_por_nombre(header.schema_context_name)
  end

  test ":index -- Eliminar borra el endpoint, su Consulta y su Header oculto", %{conn: conn, empresa: empresa} do
    header = criar_endpoint_borrador()
    consulta = MetaConsultas.obtener_por_header_id(header.id)

    {:ok, _endpoint} =
      ConsultaEndpoints.crear_o_actualizar(consulta, %{
        "nombre" => "Para borrar",
        "metodo" => "get",
        "ruta" => "para-borrar-#{unique()}",
        "empresa_id" => empresa.id,
        "parametros" => []
      })

    {:ok, view, html} = live(conn, ~p"/sysadmin/endpoints")
    assert html =~ "Para borrar"

    html_borrado = render_click(view, "eliminar_endpoint", %{"nombre" => header.schema_context_name})
    refute html_borrado =~ "Para borrar"
    refute MetaSchemaContext.obtener_header_por_nombre(header.schema_context_name)
  end

  test ":editar -- alta habilita campos reales del catálogo, y la sección Renglones no aparece sin catálogos detalle (R54-R58, R59)", %{
    conn: conn,
    empresa: empresa
  } do
    header = criar_endpoint_borrador()
    consulta = MetaConsultas.obtener_por_header_id(header.id)

    {:ok, _endpoint} =
      ConsultaEndpoints.crear_o_actualizar(consulta, %{
        "nombre" => "Alta de clientes",
        "metodo" => "post",
        "ruta" => "clientes-alta-ui-#{unique()}",
        "empresa_id" => empresa.id,
        "parametros" => []
      })

    {:ok, view, html} = live(conn, ~p"/sysadmin/endpoints/#{header.schema_context_name}")
    assert html =~ "Alta de registros"
    # meta_fixture_cliente no es maestro de ningún catálogo detalle --
    # la sub-sección "Renglones" no debe aparecer (R59).
    refute html =~ "Renglones -- crea también"

    html_guardado =
      view
      |> form("form[phx-submit=guardar_alta]", %{
        "permite_alta" => "true",
        "campos_alta" => ["meta_fixture_cliente_nombre", "meta_fixture_cliente_edad"]
      })
      |> render_submit()

    assert html_guardado =~ "Configuración de alta guardada."
    assert html_guardado =~ "meta_fixture_cliente_nombre"
    assert html_guardado =~ "201 Created"
  end
end
