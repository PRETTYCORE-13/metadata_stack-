defmodule MetadataAppWeb.UsuarioAuth do
  use MetadataAppWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.Scope

  # Sin "recordarme" -- decisión explícita 2026-08-06 (ERP transaccional
  # con datos sensibles): la cookie de sesión (Plug.Session, sin max_age,
  # ver endpoint.ex) ya muere sola al cerrar el navegador de verdad; un
  # cookie persistente aparte solo agrega superficie de riesgo (laptop
  # robada, empleado despedido) por una comodidad menor. Ver
  # UsuarioToken.@session_validity_in_hours para el límite real de cuánto
  # dura un token, independiente de si el navegador "recuerda" la cookie.

  # Reissue a mitad de camino de la ventana de validez del token (ver
  # UsuarioToken.@session_validity_in_hours, 12h): una sesión ACTIVA nunca
  # llega al corte duro (se renueva antes), mientras que una sesión
  # abandonada (nadie hace requests, nada la reissuea) sí expira -- esto
  # funciona como timeout por inactividad sin necesitar tracking aparte.
  @session_reissue_age_in_hours 6

  @doc """
  Logs the usuario in.

  Redirects to the session's `:usuario_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_usuario(conn, usuario) do
    usuario_return_to = get_session(conn, :usuario_return_to)
    conn = create_or_extend_session(conn, usuario)

    # usuario_return_to se lee una sola vez y se borra explícito acá — si no,
    # queda pegado para siempre en sesiones donde el usuario que se
    # re-loguea es el MISMO que ya estaba (renew_session/2 se salta el
    # clear_session completo a propósito en ese caso, para no romper otras
    # pestañas abiertas), y cada login futuro de esa sesión vuelve a caer
    # en la última ruta protegida que se haya visitado alguna vez, en vez
    # de ir a signed_in_path/1 como corresponde.
    case Autenticacion.empresas_de_usuario(usuario.id) do
      # Ninguna empresa asignada todavía — nada que elegir, sigue como antes.
      [] ->
        conn
        |> delete_session(:usuario_return_to)
        |> redirect(to: usuario_return_to || signed_in_path(conn))

      # Una sola empresa: se activa sola, sin pedirle que elija algo obvio.
      [%Autenticacion.Empresa{id: empresa_id}] ->
        conn
        |> put_session(:empresa_activa_id, empresa_id)
        |> delete_session(:usuario_return_to)
        |> redirect(to: usuario_return_to || signed_in_path(conn))

      # Más de una: al selector. Se resuelve el return_to recién ahí (se
      # re-escribe a propósito, no se borra, porque todavía hace falta un
      # hop más).
      _varias ->
        conn
        |> put_session(:usuario_return_to, usuario_return_to)
        |> redirect(to: ~p"/meta_schema_usuario/seleccionar-empresa")
    end
  end

  @doc """
  Logs the usuario out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_usuario(conn) do
    usuario_token = get_session(conn, :usuario_token)
    usuario_token && Autenticacion.delete_usuario_session_token(usuario_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      MetadataAppWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> redirect(to: ~p"/meta_schema_usuario/log-in")
  end

  @doc """
  Authenticates the usuario by looking into the session.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_usuario(conn, _opts) do
    with {token, conn} <- ensure_usuario_token(conn),
         {usuario, token_inserted_at} <- Autenticacion.get_usuario_by_session_token(token) do
      scope = hidratar_empresa_activa(Scope.for_usuario(usuario), get_session(conn, :empresa_activa_id))

      conn
      |> assign(:current_scope, scope)
      |> maybe_reissue_usuario_session_token(usuario, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_usuario(nil))
    end
  end

  # La empresa activa se re-valida contra meta_schema_usuario_empresa en cada
  # hidratación (no basta con confiar en el id guardado en sesión) — si le
  # revocaron acceso a esa empresa después de elegirla, el scope simplemente
  # queda sin empresa activa en vez de arrastrar una referencia inválida.
  defp hidratar_empresa_activa(nil, _empresa_id), do: nil
  defp hidratar_empresa_activa(scope, nil), do: scope

  defp hidratar_empresa_activa(%Scope{usuario: usuario} = scope, empresa_id) do
    case Autenticacion.obtener_empresa_de_usuario(usuario.id, empresa_id) do
      nil -> scope
      empresa -> Scope.con_empresa_activa(scope, empresa)
    end
  end

  defp ensure_usuario_token(conn) do
    if token = get_session(conn, :usuario_token) do
      {token, conn}
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_usuario_session_token(conn, usuario, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :hour)

    if token_age >= @session_reissue_age_in_hours do
      create_or_extend_session(conn, usuario)
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, usuario) do
    token = Autenticacion.generate_usuario_session_token(usuario)

    conn
    |> renew_session(usuario)
    |> put_token_in_session(token)
  end

  # Do not renew session if the usuario is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, usuario) when conn.assigns.current_scope.usuario.id == usuario.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _usuario) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn, _usuario) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:usuario_token, token)
    |> put_session(:live_socket_id, usuario_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      MetadataAppWeb.Endpoint.broadcast(usuario_session_topic(token), "disconnect", %{})
    end)
  end

  defp usuario_session_topic(token), do: "meta_schema_usuario_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on usuario_token, or nil if
      there's no usuario_token or no matching usuario.

    * `:require_authenticated` - Authenticates the usuario from the session,
      and assigns the current_scope to socket assigns based
      on usuario_token.
      Redirects to login page if there's no logged usuario.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule MetadataAppWeb.PageLive do
        use MetadataAppWeb, :live_view

        on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{MetadataAppWeb.UsuarioAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.usuario do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/meta_schema_usuario/log-in")

      {:halt, socket}
    end
  end

  # Igual que :require_authenticated, pero ADEMÁS exige empresa_activa
  # resuelta (2026-08-06, bug real encontrado: una sesión con usuario_token
  # válido pero SIN empresa_activa_id -- ej. una cookie vieja de antes de
  # elegir empresa -- pasaba :require_authenticated igual, current_scope
  # quedaba con empresa_activa: nil, y desde ahí dos cosas se
  # contradecían en silencio: podar_menu_por_permisos/1 (menu_layout.ex)
  # cae a "sin scope resuelto, mostrar completo" -- el sidebar se ve
  # ENTERO sin podar -- mientras que Permissions.can?/3 con
  # empresa_activa: nil siempre da false -- CUALQUIER catálogo redirige
  # con "No tienes permiso". El usuario ve todo el menú pero no puede
  # usar nada. Usado solo por la live_session "real" de la app
  # (router.ex, :app_autenticada) -- NO por :require_authenticated_usuario
  # de arriba (settings/seleccionar-empresa), que seguiría en loop
  # infinito si exigiera empresa activa para poder llegar a elegir una.
  def on_mount(:require_authenticated_con_empresa, params, session, socket) do
    case on_mount(:require_authenticated, params, session, socket) do
      {:cont, socket} ->
        if socket.assigns.current_scope.empresa_activa do
          {:cont, socket}
        else
          {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/meta_schema_usuario/seleccionar-empresa")}
        end

      {:halt, _socket} = resultado ->
        resultado
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Autenticacion.sudo_mode?(socket.assigns.current_scope.usuario, -10) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must re-authenticate to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/meta_schema_usuario/log-in")

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    socket =
      Phoenix.Component.assign_new(socket, :current_scope, fn ->
        {usuario, _} =
          if usuario_token = session["usuario_token"] do
            Autenticacion.get_usuario_by_session_token(usuario_token)
          end || {nil, nil}

        hidratar_empresa_activa(Scope.for_usuario(usuario), session["empresa_activa_id"])
      end)

    suscribir_notificaciones(socket)
  end

  # La campanita (NotifBellComponent, ver menu_layout.ex) solo recalcula su
  # badge cuando update/2 vuelve a correr — sin esto, un alta desde OTRO
  # proceso (otra pestaña, otro usuario disparando una auditoría) nunca
  # llegaba a esta pantalla hasta que el usuario recargaba el navegador a
  # mano. connected?/1 filtra el mount inicial en HTTP (todavía no hay
  # socket real al que broadcastear) — el segundo mount, ya sobre
  # websocket, es el que se suscribe de verdad. attach_hook/4 en vez de un
  # handle_info propio de cada LiveView: un solo lugar cubre TODAS las
  # pantallas autenticadas (todas pasan por acá), sin duplicar el mismo
  # handle_info en cada módulo.
  defp suscribir_notificaciones(socket) do
    usuario = socket.assigns.current_scope && socket.assigns.current_scope.usuario
    # Más de un on_mount de este módulo corre en la misma LiveView (el de
    # la live_session del router + el que cada módulo declara a mano) —
    # sin este guard, attach_hook/4 explota la segunda vez con "existing
    # hook :notif_refresh already attached".
    ya_suscrita? = Map.has_key?(socket.assigns, :notif_refresh)

    if usuario && Phoenix.LiveView.connected?(socket) && not ya_suscrita? do
      Phoenix.PubSub.subscribe(MetadataApp.PubSub, MetadataApp.Notificaciones.topic(usuario.id))

      socket
      |> Phoenix.Component.assign(:notif_refresh, 0)
      |> Phoenix.LiveView.attach_hook(:notif_refresh, :handle_info, fn
        :nueva_notificacion, socket ->
          {:halt, Phoenix.Component.assign(socket, :notif_refresh, socket.assigns.notif_refresh + 1)}

        _mensaje, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  # Antes esto distinguía "ya estaba logueado" (-> settings) de "recién se
  # logueó" (-> "/") por patrón sobre conn.assigns.current_scope.usuario —
  # pero en el call site real (log_in_usuario/3, justo después de
  # autenticar) ese assign todavía refleja el estado DE ANTES del login
  # (fetch_current_scope_for_usuario corre al principio del pipeline, la
  # sesión nueva recién se crea después), así que esa rama nunca se
  # cumplía ahí — solo en registration.ex (usuario YA autenticado visita
  # /register). Una sola ruta evita la distinción rota.
  @doc "Returns the path to redirect to after log in."
  def signed_in_path(_conn), do: ~p"/sysadmin/bc-list"

  @doc """
  Plug for routes that require the usuario to be authenticated.
  """
  def require_authenticated_usuario(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.usuario do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/meta_schema_usuario/log-in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :usuario_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
