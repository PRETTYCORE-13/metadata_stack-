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
      # activar_jerarquia_operativa/3 auto-activa branch/inventory/sales_unit
      # si el usuario solo tiene UNA opción permitida en cada uno -- pero,
      # a diferencia de empresa, NUNCA bloquea el login para ir a elegir
      # (ni con 0 asignados ni con 2+): un usuario recién migrado, sin
      # branch/inventory asignado todavía (el caso de HOY, nadie tiene esto
      # configurado), tiene que poder seguir entrando igual que siempre --
      # la pantalla de elegir queda disponible desde la banda de pie
      # (Fase 4) cuando el usuario la necesite, y el bloqueo real pasa
      # recién al intentar CREAR algo en un catálogo que de verdad exige
      # esa dimensión (Fase 5), no acá.
      [%Autenticacion.Empresa{id: empresa_id}] ->
        activar_empresa_y_continuar(conn, usuario, empresa_id, usuario_return_to)

      # Más de una -- si un admin marcó una como default (2026-08-12, ver
      # UsuariosEmpresaLive, sección "Empresa"), se activa sola, mismo
      # criterio que "una sola empresa" de arriba. Sin default (o el que
      # había dejó de ser válido -- empresa_default_de_usuario/1 revalida
      # la membresía viva), al selector; el return_to se resuelve recién
      # ahí (se re-escribe a propósito, no se borra, porque todavía hace
      # falta un hop más).
      varias when varias != [] ->
        case Autenticacion.empresa_default_de_usuario(usuario.id) do
          %Autenticacion.Empresa{id: empresa_id} ->
            activar_empresa_y_continuar(conn, usuario, empresa_id, usuario_return_to)

          nil ->
            conn
            |> put_session(:usuario_return_to, usuario_return_to)
            |> redirect(to: ~p"/meta_schema_usuario/seleccionar-empresa")
        end
    end
  end

  defp activar_empresa_y_continuar(conn, usuario, empresa_id, usuario_return_to) do
    {conn, _listo_o_pendiente} =
      conn
      |> put_session(:empresa_activa_id, empresa_id)
      |> activar_jerarquia_operativa(usuario.id, empresa_id)

    conn
    |> delete_session(:usuario_return_to)
    |> redirect(to: usuario_return_to || signed_in_path(conn))
  end

  @doc """
  Resuelve la jerarquía operativa (branch/inventory_location/sales_unit)
  de `usuario_id` en `empresa_id` y fija en sesión lo que se pueda
  auto-activar (mismo criterio que empresa_activa: una sola opción
  permitida se activa sola). Devuelve `{conn, :listo}` si branch E
  inventory_location quedaron resueltos, o `{conn, :pendiente}` si
  alguno tiene 2+ opciones o ninguna asignada todavía -- el segundo
  átomo es solo informativo, NINGÚN caller lo usa para bloquear
  navegación (a diferencia de empresa_activa): un usuario sin
  branch/inventory asignado (el caso de HOY, nadie tiene esto
  configurado todavía) tiene que poder seguir usando la app igual que
  siempre. `/meta_schema_usuario/seleccionar-jerarquia` es una pantalla
  que el usuario visita cuando quiere (desde la banda de pie, Fase 4),
  no un gate de login -- el bloqueo real pasa en Fase 5, al intentar
  crear un registro en un catálogo que de verdad exige la dimensión que
  falta.

  Usado tanto al login (una sola empresa, `log_in_usuario/2`) como al
  cambiar de empresa más tarde (`EmpresaSessionController.activar/2`) --
  la jerarquía permitida es POR empresa, así que cambiar de empresa
  siempre tiene que volver a resolver esto.
  """
  def activar_jerarquia_operativa(conn, usuario_id, empresa_id) do
    # Un administrador ve TODAS las branches/inventory/sales_units de la
    # empresa acá también (no solo lo asignado en usuario_branch/etc) --
    # mismo motivo que el selector de la banda de pie, ver el moduledoc
    # de Autenticacion.resolver_jerarquia_operativa/3.
    es_administrador? = MetadataApp.Permissions.administrador?(usuario_id, empresa_id)
    jerarquia = Autenticacion.resolver_jerarquia_operativa(usuario_id, empresa_id, es_administrador?)

    conn =
      conn
      |> aplicar_seleccion_automatica(:branch_activo_id, jerarquia.branch)
      |> aplicar_seleccion_automatica(:inventory_location_activo_id, jerarquia.inventory_location)
      |> aplicar_seleccion_automatica(:sales_unit_activo_id, jerarquia.sales_unit)

    if match?(%{branch: {:automatico, _}, inventory_location: {:automatico, _}}, jerarquia) do
      {conn, :listo}
    else
      {conn, :pendiente}
    end
  end

  defp aplicar_seleccion_automatica(conn, session_key, {:automatico, %{id: id}}), do: put_session(conn, session_key, id)
  defp aplicar_seleccion_automatica(conn, session_key, _otro), do: delete_session(conn, session_key)

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
      scope =
        Scope.for_usuario(usuario)
        |> hidratar_empresa_activa(get_session(conn, :empresa_activa_id))
        |> hidratar_alcance()
        |> hidratar_jerarquia_activa(
          get_session(conn, :branch_activo_id),
          get_session(conn, :inventory_location_activo_id),
          get_session(conn, :sales_unit_activo_id)
        )

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

  # Alcance de Datos (Fase 2, 2026-08-11) -- branches_permitidos/
  # sales_units_permitidas/inventory_locations_permitidas del Scope, resueltas
  # una vez por request/mount (mismo momento que empresa_activa). Sin empresa
  # activa todavía no hay contra qué acotar la jerarquía -- queda vacío hasta
  # que se elija una, igual que campos_editables/otras_transiciones en
  # FichaLive esperan un estado_id resuelto antes de tener sentido.
  defp hidratar_alcance(nil), do: nil
  defp hidratar_alcance(%Scope{empresa_activa: nil} = scope), do: scope

  defp hidratar_alcance(%Scope{usuario: usuario, empresa_activa: empresa} = scope) do
    alcance = Autenticacion.alcance_de_usuario(usuario.id, empresa.id)

    %{
      scope
      | branches_permitidos: alcance.branches_permitidos,
        sales_units_permitidas: alcance.sales_units_permitidas,
        inventory_locations_permitidas: alcance.inventory_locations_permitidas
    }
  end

  # Jerarquía operativa activa (branch/inventory_location/sales_unit ya
  # ELEGIDOS, no solo permitidos -- ver moduledoc de Scope). Mismo
  # criterio de revalidación que hidratar_empresa_activa/2: el id de
  # sesión se re-valida contra la asignación real en cada hidratación
  # (Autenticacion.obtener_*_de_usuario/3, que reutiliza las mismas
  # listas de branches_de_usuario/2 etc.) -- si le revocaron esa
  # sucursal/almacén después de elegirla, el scope simplemente queda sin
  # ese campo activo en vez de arrastrar una referencia inválida.
  defp hidratar_jerarquia_activa(nil, _branch_id, _inventory_id, _sales_unit_id), do: nil
  defp hidratar_jerarquia_activa(%Scope{empresa_activa: nil} = scope, _b, _i, _s), do: scope

  defp hidratar_jerarquia_activa(%Scope{usuario: usuario, empresa_activa: empresa} = scope, branch_id, inventory_id, sales_unit_id) do
    # es_administrador? faltaba acá (bug encontrado 2026-08-13): sin esto,
    # un administrador que elegía sucursal/almacén desde la banda de pie
    # (JerarquiaSessionController, que SÍ pasa es_administrador?) la
    # perdía en la siguiente carga de página -- obtener_branch_de_usuario/3
    # sin el 4to argumento solo mira lo explícitamente asignado, que un
    # admin normalmente no tiene.
    es_administrador? = MetadataApp.Permissions.administrador?(usuario.id, empresa.id)

    scope
    |> hidratar_branch_activo(usuario, empresa, branch_id, es_administrador?)
    |> hidratar_inventory_location_activo(usuario, empresa, inventory_id, es_administrador?)
    |> hidratar_sales_unit_activo(usuario, empresa, sales_unit_id, es_administrador?)
  end

  defp hidratar_branch_activo(scope, _usuario, _empresa, nil, _es_administrador?), do: scope

  defp hidratar_branch_activo(scope, usuario, empresa, branch_id, es_administrador?) do
    case Autenticacion.obtener_branch_de_usuario(usuario.id, empresa.id, branch_id, es_administrador?) do
      nil -> scope
      branch -> Scope.con_branch_activo(scope, branch)
    end
  end

  defp hidratar_inventory_location_activo(scope, _usuario, _empresa, nil, _es_administrador?), do: scope

  # Unidad Operativa (2026-08-13, arquitectura ERP: Empresa -> N Branch ->
  # N Inventory -> N Sales Unit) -- un almacén SIEMPRE es hijo de una
  # sucursal, nunca de la empresa a secas. Sin sucursal activa todavía no
  # hay contra qué contener un almacén (queda vacío, mismo criterio que
  # hidratar_alcance/1 con empresa_activa: nil). La contención en sí ya
  # NO se revisa acá con un `when` -- Autenticacion.obtener_inventory_location_de_usuario/5
  # recibe `branch_activo.id` y acota la lista operable a ESA sucursal
  # desde el origen, así que un almacén de otra sucursal ni siquiera
  # aparece como candidato (devuelve nil directo).
  defp hidratar_inventory_location_activo(%Scope{branch_activo: nil} = scope, _usuario, _empresa, _inventory_id, _es_administrador?),
    do: scope

  defp hidratar_inventory_location_activo(scope, usuario, empresa, inventory_id, es_administrador?) do
    case Autenticacion.obtener_inventory_location_de_usuario(usuario.id, empresa.id, scope.branch_activo.id, inventory_id, es_administrador?) do
      nil -> scope
      inventory_location -> Scope.con_inventory_location_activo(scope, inventory_location)
    end
  end

  defp hidratar_sales_unit_activo(scope, _usuario, _empresa, nil, _es_administrador?), do: scope

  # Mismo criterio que hidratar_inventory_location_activo/5 -- Sales Unit
  # también es hijo directo de Branch (hermano de Inventory, no anidado
  # bajo él), así que se acota contra la sucursal activa igual.
  defp hidratar_sales_unit_activo(%Scope{branch_activo: nil} = scope, _usuario, _empresa, _sales_unit_id, _es_administrador?), do: scope

  defp hidratar_sales_unit_activo(scope, usuario, empresa, sales_unit_id, es_administrador?) do
    case Autenticacion.obtener_sales_unit_de_usuario(usuario.id, empresa.id, scope.branch_activo.id, sales_unit_id, es_administrador?) do
      nil -> scope
      sales_unit -> Scope.con_sales_unit_activo(scope, sales_unit)
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

        Scope.for_usuario(usuario)
        |> hidratar_empresa_activa(session["empresa_activa_id"])
        |> hidratar_alcance()
        |> hidratar_jerarquia_activa(
          session["branch_activo_id"],
          session["inventory_location_activo_id"],
          session["sales_unit_activo_id"]
        )
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
