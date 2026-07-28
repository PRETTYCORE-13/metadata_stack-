defmodule MetadataAppWeb.Sysadmin.ConsultaEditorLiveTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaConsultas

  import MetadataApp.AutenticacionFixtures

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa editor consulta #{System.unique_integer()}"}) |> Repo.insert()

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

  defp criar_consulta do
    nombre = "consulta_editor_test_#{unique()}"

    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => "Consulta editor test",
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 3,
        "detalles" => []
      })

    {:ok, consulta} = MetaConsultas.crear(header, "meta_fixture_cliente")
    {header, consulta}
  end

  test "cambia etiqueta, visibilidad y totalizar de un campo", %{conn: conn} do
    {header, _consulta} = criar_consulta()

    {:ok, view, html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
    assert html =~ "Consulta editor test"
    assert html =~ "meta_fixture_cliente_edad"

    html_guardado =
      view
      |> form("form[phx-submit=guardar_campos]", %{
        "etiquetas" => %{"meta_fixture_cliente::meta_fixture_cliente_edad" => "Edad del cliente"},
        "visibles" => ["meta_fixture_cliente::meta_fixture_cliente_nombre"],
        "totalizar" => ["meta_fixture_cliente::meta_fixture_cliente_edad"]
      })
      |> render_submit()

    assert html_guardado =~ "Edad del cliente"

    consulta_actualizada = MetaConsultas.obtener_por_header_id(header.id)
    campo_edad = Enum.find(consulta_actualizada.campos, &(&1["campo"] == "meta_fixture_cliente_edad"))
    campo_nombre = Enum.find(consulta_actualizada.campos, &(&1["campo"] == "meta_fixture_cliente_nombre"))
    campo_venta = Enum.find(consulta_actualizada.campos, &(&1["campo"] == "meta_fixture_cliente_venta"))

    assert campo_edad["etiqueta"] == "Edad del cliente"
    assert campo_edad["totalizar"] == true
    assert campo_nombre["visible"] == true
    assert campo_venta["visible"] == false
  end

  test "el checkbox de totalizar viene disabled para un campo no numérico", %{conn: conn} do
    {header, _consulta} = criar_consulta()

    {:ok, _view, html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")

    assert html =~
             ~r/name="totalizar\[\]" value="meta_fixture_cliente::meta_fixture_cliente_nombre"\s+disabled/
  end

  # Defensa en profundidad: aunque el checkbox venga disabled en el HTML
  # (un navegador real nunca mandaría este valor), el submit real
  # (render_submit(view, evento, params)) no pasa por la validación de
  # LiveViewTest contra el DOM — simula un cliente manipulado mandando el
  # evento directo, y confirma que guardar_campos/3 igual lo descarta
  # server-side por el tipo del campo.
  test "guardar_campos ignora totalizar para un campo no numérico aunque llegue en el evento", %{conn: conn} do
    {header, _consulta} = criar_consulta()

    {:ok, view, _html} = live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")

    render_submit(view, "guardar_campos", %{"totalizar" => ["meta_fixture_cliente::meta_fixture_cliente_nombre"]})

    consulta_actualizada = MetaConsultas.obtener_por_header_id(header.id)
    campo_nombre = Enum.find(consulta_actualizada.campos, &(&1["campo"] == "meta_fixture_cliente_nombre"))

    assert campo_nombre["totalizar"] == false
  end

  test "un header que no es Consulta redirige a bc-list", %{conn: conn} do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => "no_es_consulta_#{unique()}",
        "schema_context_label" => "No es consulta",
        "schema_context_nav" => "/no_es_consulta_#{unique()}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => []
      })

    assert {:error, {:live_redirect, %{to: "/sysadmin/bc-list"}}} =
             live(conn, ~p"/sysadmin/bc-list/#{header.schema_context_name}/consulta")
  end
end
