defmodule MetadataAppWeb.CatalogoLiveConsultaTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataApp.MetaConsultas
  alias MetadataApp.Permissions

  import MetadataApp.AutenticacionFixtures

  # Consulta Ecto (schema_context_type: 3) sobre el catálogo fixture
  # meta_fixture_cliente — mismo criterio que meta_transicion_controller_test:
  # administrador ve cualquier permiso YA REGISTRADO sin rol_permiso
  # explícito, así que alcanza con loguearse como tal y registrar el "leer"
  # de la consulta (nadie lo hace automático al crearla, ver
  # CatalogoPermisosLive/buscar_catalogos/2).
  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa consulta test #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn}
  end

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp fixture_cliente(attrs) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(attrs)
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp criar_consulta_sobre_fixture do
    nav = "/consulta_fixture_test_#{unique()}"
    nombre = "consulta_fixture_test_#{unique()}"

    {:ok, {header, _detalles}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Consulta fixture de prueba",
        "schema_context_nav" => nav,
        "schema_visible" => true,
        "schema_context_type" => 3,
        "detalles" => []
      })

    {:ok, consulta} = MetaConsultas.crear(header, "meta_fixture_cliente")
    {:ok, _} = Permissions.crear_permiso(%{recurso: nombre, accion: "leer"})

    {header, consulta, nav}
  end

  test "monta la consulta, lista filas reales y respeta filtro por campo", %{conn: conn} do
    fixture_cliente(%{
      meta_fixture_cliente_nombre: "Cliente Uno #{unique()}",
      meta_fixture_cliente_edad: 30,
      meta_fixture_cliente_venta: Decimal.new("100.00")
    })

    cliente_dos =
      fixture_cliente(%{
        meta_fixture_cliente_nombre: "Cliente Dos #{unique()}",
        meta_fixture_cliente_edad: 45,
        meta_fixture_cliente_venta: Decimal.new("250.00")
      })

    {_header, _consulta, nav} = criar_consulta_sobre_fixture()

    {:ok, view, html} = live(conn, nav)

    assert html =~ "Consulta fixture de prueba"
    assert html =~ cliente_dos.meta_fixture_cliente_nombre

    html_filtrado =
      view
      |> render_change("filtrar", %{"filtros" => %{"meta_fixture_cliente_nombre" => cliente_dos.meta_fixture_cliente_nombre}})

    assert html_filtrado =~ cliente_dos.meta_fixture_cliente_nombre
    refute html_filtrado =~ "Cliente Uno"
  end

  test "la banda de totales suma solo la columna marcada totalizar", %{conn: conn} do
    fixture_cliente(%{meta_fixture_cliente_nombre: "A #{unique()}", meta_fixture_cliente_edad: 10, meta_fixture_cliente_venta: Decimal.new("1")})
    fixture_cliente(%{meta_fixture_cliente_nombre: "B #{unique()}", meta_fixture_cliente_edad: 20, meta_fixture_cliente_venta: Decimal.new("1")})

    {_header, consulta, nav} = criar_consulta_sobre_fixture()

    campos =
      Enum.map(consulta.campos, fn c ->
        if c["campo"] == "meta_fixture_cliente_edad", do: Map.put(c, "totalizar", true), else: c
      end)

    {:ok, _} = MetaConsultas.actualizar_campos(consulta, campos)

    {:ok, _view, html} = live(conn, nav)

    assert html =~ ~r/<tfoot.*?>.*?30.*?<\/tfoot>/s
  end
end
