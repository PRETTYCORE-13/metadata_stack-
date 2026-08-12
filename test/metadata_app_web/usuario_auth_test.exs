defmodule MetadataAppWeb.UsuarioAuthTest do
  use MetadataAppWeb.ConnCase, async: true

  alias Phoenix.LiveView
  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.Scope
  alias MetadataAppWeb.UsuarioAuth

  import MetadataApp.AutenticacionFixtures

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, MetadataAppWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{usuario: %{usuario_fixture() | authenticated_at: DateTime.utc_now(:second)}, conn: conn}
  end

  describe "log_in_usuario/2" do
    test "stores the usuario token in the session", %{conn: conn, usuario: usuario} do
      conn = UsuarioAuth.log_in_usuario(conn, usuario)
      assert token = get_session(conn, :usuario_token)
      assert get_session(conn, :live_socket_id) == "meta_schema_usuario_sessions:#{Base.url_encode64(token)}"
      assert redirected_to(conn) == ~p"/sysadmin/bc-list"
      assert Autenticacion.get_usuario_by_session_token(token)
    end

    test "clears everything previously stored in the session", %{conn: conn, usuario: usuario} do
      conn = conn |> put_session(:to_be_removed, "value") |> UsuarioAuth.log_in_usuario(usuario)
      refute get_session(conn, :to_be_removed)
    end

    test "keeps session when re-authenticating", %{conn: conn, usuario: usuario} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_usuario(usuario))
        |> put_session(:to_be_removed, "value")
        |> UsuarioAuth.log_in_usuario(usuario)

      assert get_session(conn, :to_be_removed)
    end

    test "clears session when usuario does not match when re-authenticating", %{
      conn: conn,
      usuario: usuario
    } do
      other_usuario = usuario_fixture()

      conn =
        conn
        |> assign(:current_scope, Scope.for_usuario(other_usuario))
        |> put_session(:to_be_removed, "value")
        |> UsuarioAuth.log_in_usuario(usuario)

      refute get_session(conn, :to_be_removed)
    end

    test "redirects to the configured path", %{conn: conn, usuario: usuario} do
      conn = conn |> put_session(:usuario_return_to, "/hello") |> UsuarioAuth.log_in_usuario(usuario)
      assert redirected_to(conn) == "/hello"
    end

    test "redirects to bc-list when usuario is already logged in", %{conn: conn, usuario: usuario} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_usuario(usuario))
        |> UsuarioAuth.log_in_usuario(usuario)

      assert redirected_to(conn) == ~p"/sysadmin/bc-list"
    end
  end

  describe "logout_usuario/1" do
    test "erases session", %{conn: conn, usuario: usuario} do
      usuario_token = Autenticacion.generate_usuario_session_token(usuario)

      conn =
        conn
        |> put_session(:usuario_token, usuario_token)
        |> fetch_cookies()
        |> UsuarioAuth.log_out_usuario()

      refute get_session(conn, :usuario_token)
      assert redirected_to(conn) == ~p"/meta_schema_usuario/log-in"
      refute Autenticacion.get_usuario_by_session_token(usuario_token)
    end

    test "broadcasts to the given live_socket_id", %{conn: conn} do
      live_socket_id = "meta_schema_usuario_sessions:abcdef-token"
      MetadataAppWeb.Endpoint.subscribe(live_socket_id)

      conn
      |> put_session(:live_socket_id, live_socket_id)
      |> UsuarioAuth.log_out_usuario()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}
    end

    test "works even if usuario is already logged out", %{conn: conn} do
      conn = conn |> fetch_cookies() |> UsuarioAuth.log_out_usuario()
      refute get_session(conn, :usuario_token)
      assert redirected_to(conn) == ~p"/meta_schema_usuario/log-in"
    end
  end

  describe "fetch_current_scope_for_usuario/2" do
    test "authenticates usuario from session", %{conn: conn, usuario: usuario} do
      usuario_token = Autenticacion.generate_usuario_session_token(usuario)

      conn =
        conn |> put_session(:usuario_token, usuario_token) |> UsuarioAuth.fetch_current_scope_for_usuario([])

      assert conn.assigns.current_scope.usuario.id == usuario.id
      assert conn.assigns.current_scope.usuario.authenticated_at == usuario.authenticated_at
      assert get_session(conn, :usuario_token) == usuario_token
    end

    test "does not authenticate if data is missing", %{conn: conn, usuario: usuario} do
      _ = Autenticacion.generate_usuario_session_token(usuario)
      conn = UsuarioAuth.fetch_current_scope_for_usuario(conn, [])
      refute get_session(conn, :usuario_token)
      refute conn.assigns.current_scope
    end

    test "reissues a new token once it's past the reissue age (sesión activa, se renueva sola)", %{
      conn: conn,
      usuario: usuario
    } do
      token = Autenticacion.generate_usuario_session_token(usuario)
      offset_usuario_token(token, -7, :hour)

      conn =
        conn
        |> put_session(:usuario_token, token)
        |> UsuarioAuth.fetch_current_scope_for_usuario([])

      assert conn.assigns.current_scope.usuario.id == usuario.id
      assert new_token = get_session(conn, :usuario_token)
      assert new_token != token
    end

    # Fase 2 del modelo de Alcance de Datos (2026-08-11) -- confirma que
    # hidratar_alcance/1 corre de verdad en el mismo pipeline que
    # empresa_activa, no solo que Autenticacion.alcance_de_usuario/2 (la
    # función de contexto) funcione aislada.
    test "hidrata branches/sales_units/inventory_locations permitidos del usuario en la empresa activa", %{
      conn: conn,
      usuario: usuario
    } do
      {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa scope test #{System.unique_integer()}", usuario.id)
      {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})

      {:ok, sales_unit} =
        Autenticacion.crear_sales_unit(%{empresa_id: empresa.id, branch_id: branch.id, sales_unit_name: "Preventa 1"})

      {:ok, inventory_location} =
        Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Producto terminado"})

      {:ok, _} = Autenticacion.asignar_branch(usuario.id, branch.id)
      {:ok, _} = Autenticacion.asignar_sales_unit(usuario.id, sales_unit.id)
      {:ok, _} = Autenticacion.asignar_inventory_location(usuario.id, inventory_location.id)

      usuario_token = Autenticacion.generate_usuario_session_token(usuario)

      conn =
        conn
        |> put_session(:usuario_token, usuario_token)
        |> put_session(:empresa_activa_id, empresa.id)
        |> UsuarioAuth.fetch_current_scope_for_usuario([])

      scope = conn.assigns.current_scope
      assert scope.empresa_activa.id == empresa.id
      assert scope.branches_permitidos == [branch.id]
      assert scope.sales_units_permitidas == [sales_unit.id]
      assert scope.inventory_locations_permitidas == [inventory_location.id]
    end

    test "sin empresa activa, el alcance queda vacío (nada contra qué acotar la jerarquía)", %{conn: conn, usuario: usuario} do
      usuario_token = Autenticacion.generate_usuario_session_token(usuario)
      conn = conn |> put_session(:usuario_token, usuario_token) |> UsuarioAuth.fetch_current_scope_for_usuario([])

      scope = conn.assigns.current_scope
      refute scope.empresa_activa
      assert scope.branches_permitidos == []
    end
  end

  describe "on_mount :mount_current_scope" do
    setup %{conn: conn} do
      %{conn: UsuarioAuth.fetch_current_scope_for_usuario(conn, [])}
    end

    test "assigns current_scope based on a valid usuario_token", %{conn: conn, usuario: usuario} do
      usuario_token = Autenticacion.generate_usuario_session_token(usuario)
      session = conn |> put_session(:usuario_token, usuario_token) |> get_session()

      {:cont, updated_socket} =
        UsuarioAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope.usuario.id == usuario.id
    end

    test "assigns nil to current_scope assign if there isn't a valid usuario_token", %{conn: conn} do
      usuario_token = "invalid_token"
      session = conn |> put_session(:usuario_token, usuario_token) |> get_session()

      {:cont, updated_socket} =
        UsuarioAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope == nil
    end

    test "assigns nil to current_scope assign if there isn't a usuario_token", %{conn: conn} do
      session = conn |> get_session()

      {:cont, updated_socket} =
        UsuarioAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope == nil
    end
  end

  describe "on_mount :require_authenticated" do
    test "authenticates current_scope based on a valid usuario_token", %{conn: conn, usuario: usuario} do
      usuario_token = Autenticacion.generate_usuario_session_token(usuario)
      session = conn |> put_session(:usuario_token, usuario_token) |> get_session()

      {:cont, updated_socket} =
        UsuarioAuth.on_mount(:require_authenticated, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope.usuario.id == usuario.id
    end

    test "redirects to login page if there isn't a valid usuario_token", %{conn: conn} do
      usuario_token = "invalid_token"
      session = conn |> put_session(:usuario_token, usuario_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: MetadataAppWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UsuarioAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope == nil
    end

    test "redirects to login page if there isn't a usuario_token", %{conn: conn} do
      session = conn |> get_session()

      socket = %LiveView.Socket{
        endpoint: MetadataAppWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UsuarioAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope == nil
    end
  end

  describe "on_mount :require_sudo_mode" do
    test "allows meta_schema_usuario that have authenticated in the last 10 minutes", %{conn: conn, usuario: usuario} do
      usuario_token = Autenticacion.generate_usuario_session_token(usuario)
      session = conn |> put_session(:usuario_token, usuario_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: MetadataAppWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:cont, _updated_socket} =
               UsuarioAuth.on_mount(:require_sudo_mode, %{}, session, socket)
    end

    test "redirects when authentication is too old", %{conn: conn, usuario: usuario} do
      eleven_minutes_ago = DateTime.utc_now(:second) |> DateTime.add(-11, :minute)
      usuario = %{usuario | authenticated_at: eleven_minutes_ago}
      usuario_token = Autenticacion.generate_usuario_session_token(usuario)
      {usuario, token_inserted_at} = Autenticacion.get_usuario_by_session_token(usuario_token)
      assert DateTime.compare(token_inserted_at, usuario.authenticated_at) == :gt
      session = conn |> put_session(:usuario_token, usuario_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: MetadataAppWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:halt, _updated_socket} =
               UsuarioAuth.on_mount(:require_sudo_mode, %{}, session, socket)
    end
  end

  describe "require_authenticated_usuario/2" do
    setup %{conn: conn} do
      %{conn: UsuarioAuth.fetch_current_scope_for_usuario(conn, [])}
    end

    test "redirects if usuario is not authenticated", %{conn: conn} do
      conn = conn |> fetch_flash() |> UsuarioAuth.require_authenticated_usuario([])
      assert conn.halted

      assert redirected_to(conn) == ~p"/meta_schema_usuario/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to access this page."
    end

    test "stores the path to redirect to on GET", %{conn: conn} do
      halted_conn =
        %{conn | path_info: ["foo"], query_string: ""}
        |> fetch_flash()
        |> UsuarioAuth.require_authenticated_usuario([])

      assert halted_conn.halted
      assert get_session(halted_conn, :usuario_return_to) == "/foo"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar=baz"}
        |> fetch_flash()
        |> UsuarioAuth.require_authenticated_usuario([])

      assert halted_conn.halted
      assert get_session(halted_conn, :usuario_return_to) == "/foo?bar=baz"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar", method: "POST"}
        |> fetch_flash()
        |> UsuarioAuth.require_authenticated_usuario([])

      assert halted_conn.halted
      refute get_session(halted_conn, :usuario_return_to)
    end

    test "does not redirect if usuario is authenticated", %{conn: conn, usuario: usuario} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_usuario(usuario))
        |> UsuarioAuth.require_authenticated_usuario([])

      refute conn.halted
      refute conn.status
    end
  end

  describe "disconnect_sessions/1" do
    test "broadcasts disconnect messages for each token" do
      tokens = [%{token: "token1"}, %{token: "token2"}]

      for %{token: token} <- tokens do
        MetadataAppWeb.Endpoint.subscribe("meta_schema_usuario_sessions:#{Base.url_encode64(token)}")
      end

      UsuarioAuth.disconnect_sessions(tokens)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: "meta_schema_usuario_sessions:dG9rZW4x"
      }

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: "meta_schema_usuario_sessions:dG9rZW4y"
      }
    end
  end
end
