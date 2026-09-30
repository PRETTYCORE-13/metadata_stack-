defmodule MetadataAppWeb.Sysadmin.ServiciosLiveTest do
  @moduledoc "SPEC-SYS-2509202601 P7 (R53.1-R53.2): sección Servicios en cualquier ambiente."
  # async: false -- un test simula un ambiente sin bpb_habilitado.
  use MetadataAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.{Repo, ConsultasSql, ConsultaEndpoints}
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}

  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{}
      |> Empresa.changeset(%{nombre: "Empresa servicios #{System.unique_integer()}"})
      |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{}
      |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id})
      |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = MetadataApp.Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    %{
      conn:
        conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id),
      empresa: empresa
    }
  end

  defp crear_servicio(empresa, con_endpoint?) do
    {:ok, {header, _}} =
      ConsultasSql.crear(%{
        "etiqueta" => "Precio test",
        "nav" => "/precio_test_#{System.unique_integer([:positive])}",
        "uso" => "servicio"
      })

    nombre = header.schema_context_name

    {:ok, servicio} =
      ConsultasSql.guardar_sql(nombre, "SELECT :x AS x, 'a' AS y", %{
        "parametros" => [%{"nombre" => "x", "tipo" => "entero", "obligatorio" => true}]
      })

    if con_endpoint? do
      {:ok, _} =
        ConsultaEndpoints.crear_o_actualizar(servicio, %{
          "nombre" => "Precio",
          "metodo" => "post",
          "ruta" => "precio-#{System.unique_integer([:positive])}",
          "empresa_id" => empresa.id
        })
    end

    {nombre, servicio}
  end

  test ":index lista los Servicios y abre su detalle", %{conn: conn, empresa: empresa} do
    {nombre, _} = crear_servicio(empresa, true)

    {:ok, view, _html} = live(conn, ~p"/sysadmin/servicios")
    refute has_element?(view, "#servicio-#{nombre}", "PUBLICADO")
    assert has_element?(view, "#servicio-#{nombre}", "BORRADOR")

    view |> element("#abrir-servicio-#{nombre}") |> render_click()
    assert_redirect(view, ~p"/sysadmin/servicios/#{nombre}")
  end

  test ":ver crea, regenera y revoca credenciales", %{conn: conn, empresa: empresa} do
    {nombre, servicio} = crear_servicio(empresa, true)
    endpoint = ConsultasSql.endpoint_del_servicio(servicio)

    {:ok, view, _html} = live(conn, ~p"/sysadmin/servicios/#{nombre}")
    assert has_element?(view, "#contrato-ruta-endpoint", endpoint.ruta)
    assert has_element?(view, "#editar-sql-servicio")

    view
    |> form("#form-credencial", %{"credencial" => %{"nombre" => "App", "campos" => ["x"]}})
    |> render_submit()

    assert has_element?(view, "#key-temporal")
    [credencial] = ConsultaEndpoints.listar_credenciales(endpoint.id)

    view |> element("#ocultar-key") |> render_click()
    refute has_element?(view, "#key-temporal")

    view |> element("#regenerar-#{credencial.id}") |> render_click()
    assert has_element?(view, "#key-temporal")
    [regenerada] = ConsultaEndpoints.listar_credenciales(endpoint.id)
    assert regenerada.api_key_hash != credencial.api_key_hash

    view |> element("#revocar-#{credencial.id}") |> render_click()
    assert [%{estado: "revocada"}] = ConsultaEndpoints.listar_credenciales(endpoint.id)
  end

  test "R53.2: fuera de local no se crea ni publica el Endpoint, pero sí las credenciales", %{
    conn: conn,
    empresa: empresa
  } do
    {con_endpoint, servicio} = crear_servicio(empresa, true)
    {sin_endpoint, _} = crear_servicio(empresa, false)
    endpoint = ConsultasSql.endpoint_del_servicio(servicio)

    anterior = Application.get_env(:metadata_app, :bpb_habilitado)
    Application.put_env(:metadata_app, :bpb_habilitado, false)
    on_exit(fn -> Application.put_env(:metadata_app, :bpb_habilitado, anterior) end)

    {:ok, view, _html} = live(conn, ~p"/sysadmin/servicios/#{sin_endpoint}")
    refute has_element?(view, "#form-endpoint")
    refute has_element?(view, "#editar-sql-servicio")

    {:ok, view, _html} = live(conn, ~p"/sysadmin/servicios/#{con_endpoint}")
    refute has_element?(view, "#publicar-endpoint")
    render_click(view, "publicar_endpoint", %{})
    assert ConsultasSql.endpoint_del_servicio(servicio).estado == "borrador"

    view
    |> form("#form-credencial", %{"credencial" => %{"nombre" => "App", "campos" => ["x"]}})
    |> render_submit()

    assert has_element?(view, "#key-temporal")
    assert [_] = ConsultaEndpoints.listar_credenciales(endpoint.id)
  end

  test "un nombre que no es Servicio regresa a la lista", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/sysadmin/servicios"}}} =
             live(conn, ~p"/sysadmin/servicios/no_existe_#{System.unique_integer([:positive])}")
  end
end
