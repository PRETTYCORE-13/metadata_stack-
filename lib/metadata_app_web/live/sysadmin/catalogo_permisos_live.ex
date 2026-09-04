defmodule MetadataAppWeb.Sysadmin.CatalogoPermisosLive do
  @moduledoc """
  Vista invertida de `RolDetalleLive` (Fase A del roadmap, ver
  `docs/roadmap-rbac-extension.md`): fija UN catálogo y muestra TODOS los
  roles de la empresa (o solo los de un usuario puntual) con sus toggles
  de leer/crear/editar/eliminar + transiciones reales de ESE catálogo.

  Mismo criterio de escala que el resto de RBAC: el selector de catálogo
  de la izquierda es un buscador con tope de resultados
  (`Permissions.buscar_catalogos/2`), nunca una lista fija — a
  +1000 catálogos posibles no se puede cargar el universo entero.

  Edición todavía instantánea (cada toggle escribe al toque) — el modo
  "borrador + confirmar" (punto 4 del pedido) queda para la próxima
  entrega, a propósito, para no mezclar dos cambios de comportamiento a
  la vez.
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_catalogos_permisos", "leer"}}

  alias MetadataApp.Permissions
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaConsultas
  alias MetadataAppWeb.AdminNav

  @acciones_crud ~w(leer crear editar eliminar)

  # Fase 6 del modelo de Alcance de Datos (2026-08-11) -- valores válidos
  # de <select>, en el mismo orden que la jerarquía real (de más
  # restrictivo a más amplio), para que el dropdown se lea de arriba a
  # abajo como una escala.
  @tipos_alcance [
    {"Solo lo propio", "propio"},
    {"Su ubicación de inventario", "inventory_location"},
    {"Su unidad de ventas", "sales_unit"},
    {"Su sucursal", "branch"},
    {"Toda la empresa", "empresa"},
    {"Todas las empresas", "global"}
  ]

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "tepache", label: "Tepache Exp/Imp", nav: "/sysadmin/tepache"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"},
    %{tipo: :pagina, id: "credenciales", label: "Credenciales", nav: "/sysadmin/credenciales"},
    %{tipo: :pagina, id: "ambientes", label: "Ambientes de Deploy", nav: "/sysadmin/ambientes"},
    %{tipo: :pagina, id: "acciones_externas", label: "Acciones externas", nav: "/sysadmin/acciones-externas"},
    %{tipo: :pagina, id: "jerarquia", label: "Jerarquía organizacional", nav: "/sysadmin/jerarquia"},
  %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"},
  %{tipo: :pagina, id: "sesiones_movil", label: "Sesiones móviles", nav: "/sysadmin/sesiones-movil"}
  ]

  # Esta LiveView NUNCA define handle_params/3 — a propósito. También se
  # usa embebida en el tab "Permisos" de BcMotorLive (live_render/3, mismo
  # criterio que PlantillaConstructorLive en "PostView"), y un módulo
  # montado como hijo tiene `socket.root_pid != self()` siempre, lo que
  # hace que Phoenix.LiveView.Channel.maybe_call_mount_handle_params/4
  # fuerce `router: nil` y reviente con "cannot invoke handle_params/3...
  # because it is not mounted nor accessed through the router live/3
  # macro" apenas conecta el WebSocket — pasa para CUALQUIER LiveView con
  # handle_params/3 usado como hijo, no es un bug de esta pantalla. Por
  # eso toda la resolución de "recurso" vive acá, en mount/3 (routeado
  # con recurso en la URL, routeado sin recurso, o embebido con recurso
  # por session — un hijo SIEMPRE recibe `params` fijo en el átomo
  # `:not_mounted_at_router`, así que ahí el dato viaja por `session`) — y
  # el picker de abajo usa push_navigate/2 (remonta entero) en vez de
  # push_patch/2 (que dependía de handle_params para reaccionar).
  def mount(%{"recurso" => recurso}, _session, socket) do
    socket =
      socket
      |> montar_base()
      |> assign(:embebido?, false)
      |> assign(:current_page, "roles")
      |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
      |> assign(:sidebar_open, false)
      |> assign(:show_programacion_children, false)
      |> assign(:show_clientes_children, false)
      |> assign(:show_prettycore_children, false)
      |> montar_catalogo(recurso)

    socket =
      if socket.assigns.catalogo do
        socket
      else
        socket
        |> put_flash(:error, "Ese catálogo no existe.")
        |> push_navigate(to: ~p"/sysadmin/catalogos/permisos")
      end

    {:ok, socket}
  end

  # Embebido en el tab "Permisos" de BcMotorLive — el catálogo queda FIJO
  # (nunca cambia dentro de esta instancia), sin picker de la izquierda
  # ni link "volver" (ver render/1, `@embebido?`), porque ya se está
  # adentro de ese BC en BcMotorLive.
  def mount(_params, %{"recurso" => recurso}, socket) do
    {:ok, socket |> montar_base() |> assign(:embebido?, true) |> montar_catalogo(recurso)}
  end

  # Entrada directa "Permission Sets" del submenú (sin BC List de por
  # medio, que no existe en producción) — sin recurso todavía, solo el
  # buscador de la izquierda hasta que se elija uno.
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> montar_base()
     |> assign(:embebido?, false)
     |> assign(:current_page, "roles")
     |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> assign(:catalogo, nil)
     |> assign(:transiciones, [])}
  end

  defp montar_base(socket) do
    socket
    |> assign(:acciones_crud, @acciones_crud)
    |> assign(:catalogo_base_de_consulta, nil)
    |> assign(:busqueda_catalogo_picker, "")
    |> assign(:resultados_catalogo_picker, [])
    |> assign(:modo, :todos)
    |> assign(:busqueda_usuario, "")
    |> assign(:resultados_usuario, [])
    |> assign(:usuario_seleccionado, nil)
    |> assign(:roles, [])
    |> assign(:roles_con_permiso, [])
    |> assign(:estado, %{})
    |> assign(:alcance_por_rol, %{})
    |> assign(:tipos_alcance, @tipos_alcance)
    |> assign(:alcance_error, nil)
    |> assign(:mostrar_sysadmin?, false)
  end

  defp montar_catalogo(socket, recurso) do
    case Permissions.obtener_catalogo(recurso) do
      nil ->
        socket |> assign(:catalogo, nil) |> assign(:transiciones, [])

      catalogo ->
        socket
        |> assign(:catalogo, catalogo)
        |> assign(:catalogo_base_de_consulta, catalogo_base_de_consulta(catalogo))
        |> assign(:transiciones, Permissions.transiciones_de_catalogos([recurso]) |> Map.get(recurso, []))
        |> cargar_matriz()
    end
  end

  # Una Consulta Ecto no tiene Alcance de Datos propio -- no tiene
  # branch_id/sales_unit_id/etc. de sí misma, hereda el de catalogo_base
  # (ver MetaConsultas.aplicar_alcance_de_datos/4). Esta pantalla, para
  # una Consulta, muestra ese estado en modo solo-lectura en vez de la
  # sección de toggle+config por rol (ver :if en render/1 de más abajo).
  defp catalogo_base_de_consulta(%{es_consulta: true, id: header_id}) do
    consulta = MetaConsultas.obtener_por_header_id(header_id)
    header_base = MetaSchemaContext.obtener_header_por_nombre(consulta.catalogo_base)
    %{nombre: consulta.catalogo_base, label: header_base.schema_context_label, alcance_habilitado: header_base.alcance_habilitado}
  end

  defp catalogo_base_de_consulta(_catalogo), do: nil

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "roles")
  end

  def handle_event("buscar_catalogo_picker", %{"value" => texto}, socket) do
    resultados = Permissions.buscar_catalogos(texto)
    {:noreply, socket |> assign(:busqueda_catalogo_picker, texto) |> assign(:resultados_catalogo_picker, resultados)}
  end

  def handle_event("elegir_catalogo", %{"recurso" => recurso}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/sysadmin/catalogos/#{recurso}/permisos")}
  end

  def handle_event("ver_todos_los_roles", _params, socket) do
    {:noreply,
     socket
     |> assign(modo: :todos, usuario_seleccionado: nil, busqueda_usuario: "", resultados_usuario: [])
     |> cargar_matriz()}
  end

  # Mismo criterio que RolesLive: el checkbox ya está oculto para
  # cualquiera que no sea super_admin (ver :if en el render) -- este
  # chequeo server-side es defensa en profundidad.
  def handle_event("toggle_mostrar_sysadmin", _params, socket) do
    if socket.assigns.current_scope.usuario.super_admin do
      {:noreply, socket |> update(:mostrar_sysadmin?, &(!&1)) |> cargar_matriz()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("buscar_usuario", %{"value" => texto}, socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id
    resultados = Permissions.buscar_usuarios_de_la_empresa(empresa_id, texto)
    {:noreply, socket |> assign(:busqueda_usuario, texto) |> assign(:resultados_usuario, resultados)}
  end

  def handle_event("elegir_usuario_filtro", %{"id" => usuario_id}, socket) do
    usuario = Enum.find(socket.assigns.resultados_usuario, &(&1.id == String.to_integer(usuario_id)))

    {:noreply,
     socket
     |> assign(modo: :por_usuario, usuario_seleccionado: usuario, busqueda_usuario: "", resultados_usuario: [])
     |> cargar_matriz()}
  end

  def handle_event("toggle_permiso", %{"rol_id" => rol_id, "accion" => accion}, socket) do
    rol_id = String.to_integer(rol_id)
    recurso = socket.assigns.catalogo.recurso
    estado = Map.get(socket.assigns.estado, {rol_id, accion}, %{permiso_id: nil, concedido: false})

    if estado.concedido do
      Permissions.revocar_permiso_de_rol(rol_id, estado.permiso_id)
    else
      Permissions.conceder_permiso_catalogo(rol_id, recurso, accion)
    end

    {:noreply, cargar_matriz(socket)}
  end

  # Conceder/revocar TODAS las acciones (CRUD + transiciones) de este
  # catálogo para un rol en un solo click — agilizar la selección cuando
  # un rol necesita quedar con acceso total (o ninguno) a un catálogo,
  # sin tildar botón por botón. Salta las que ya están en el estado
  # deseado (no reintenta conceder lo ya concedido ni revocar lo ya
  # revocado) — mismo criterio idempotente que toggle_permiso.
  def handle_event("conceder_todos", %{"rol_id" => rol_id}, socket) do
    rol_id = String.to_integer(rol_id)
    recurso = socket.assigns.catalogo.recurso

    pares =
      todas_las_acciones(socket)
      |> Enum.reject(&Map.get(socket.assigns.estado, {rol_id, &1}, %{concedido: false}).concedido)
      |> Enum.map(&{recurso, &1})

    Permissions.conceder_permisos_catalogo(rol_id, pares)

    {:noreply, cargar_matriz(socket)}
  end

  def handle_event("revocar_todos", %{"rol_id" => rol_id}, socket) do
    rol_id = String.to_integer(rol_id)
    recurso = socket.assigns.catalogo.recurso

    pares =
      todas_las_acciones(socket)
      |> Enum.filter(&Map.get(socket.assigns.estado, {rol_id, &1}, %{concedido: false}).concedido)
      |> Enum.map(&{recurso, &1})

    Permissions.revocar_permisos_de_rol(rol_id, pares)

    {:noreply, cargar_matriz(socket)}
  end

  # Fase 6 del modelo de Alcance de Datos -- upsert directo, mismo criterio
  # inmediato (sin confirmar) que toggle_permiso/2. "propio" con un select
  # vacío no debería pasar (el <select> siempre manda un valor), pero por
  # las dudas: nunca revoca la fila si tipo viene vacío, mejor dejarla
  # como estaba que perder la concesión por un evento raro.
  # Defensa en profundidad: el UI ya oculta el form de alcance por rol
  # para una Consulta (ver catalogo_base_de_consulta/1 y render/1), esto
  # cubre un evento manual/directo igual.
  def handle_event("cambiar_alcance_tipo", _params, %{assigns: %{catalogo: %{es_consulta: true}}} = socket) do
    {:noreply, put_flash(socket, :error, "Una Consulta no tiene Alcance de Datos propio -- se configura en el catálogo base.")}
  end

  def handle_event("cambiar_alcance_tipo", %{"rol_id" => rol_id, "tipo" => tipo}, socket) when tipo != "" do
    rol_id = String.to_integer(rol_id)
    Permissions.definir_alcance_de_rol(rol_id, socket.assigns.catalogo.id, tipo)
    {:noreply, cargar_matriz(socket)}
  end

  def handle_event("cambiar_alcance_tipo", _params, socket), do: {:noreply, socket}

  # Relocado acá desde BcMotorLive/Get View (2026-08-12, ajuste UI:
  # "revuelve mucho" tener el on/off en una pestaña y la config por rol en
  # otra — ahora activar/desactivar y `panel_alcance_de_rol` viven juntos).
  # Apagar solo pisa el flag (nunca borra columnas físicas ni filas de
  # `meta_schema_rol_alcance` — reversible sin pérdida, mismo criterio que
  # ya tenía el toggle original). Prender usa `provisionar_alcance/1`, NO
  # `activar_alcance_con_default_sucursal/1` (esa es solo para cuando un
  # BC nace, ver MetaSchemaContext) -- togglear acá nunca pisa el
  # alcance_tipo que un admin ya haya configurado por rol.
  def handle_event("toggle_alcance_habilitado", _params, %{assigns: %{catalogo: %{es_consulta: true}}} = socket) do
    {:noreply, put_flash(socket, :error, "Una Consulta no tiene Alcance de Datos propio -- se configura en el catálogo base.")}
  end

  def handle_event("toggle_alcance_habilitado", _params, socket) do
    catalogo = socket.assigns.catalogo
    header = MetaSchemaContext.obtener_header_por_nombre(catalogo.recurso)
    valor = !catalogo.alcance_habilitado

    resultado =
      if valor do
        MetaSchemaContext.provisionar_alcance(header)
      else
        MetaSchemaContext.actualizar_header(header, %{"alcance_habilitado" => false})
      end

    case resultado do
      {:ok, _header_actualizado} ->
        {:noreply,
         socket
         |> assign(:alcance_error, nil)
         |> assign(:catalogo, Permissions.obtener_catalogo(catalogo.recurso))
         |> cargar_matriz()}

      {:error, _motivo} ->
        {:noreply, assign(socket, :alcance_error, "No se pudo actualizar \"Alcance de datos\".")}
    end
  end

  defp todas_las_acciones(socket), do: socket.assigns.acciones_crud ++ Enum.map(socket.assigns.transiciones, & &1.accion)

  defp cargar_matriz(socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id
    recurso = socket.assigns.catalogo.recurso

    roles =
      case socket.assigns.modo do
        :todos ->
          # Mismo motivo que en RolesLive: los 10 roles "acceso_sysadmin_*"
          # son ruido para cualquiera que esté configurando permisos de UN
          # catálogo de negocio -- ocultos por default, solo super_admin
          # los puede traer con el checkbox. Modo :por_usuario abajo NO se
          # filtra: ahí se muestra lo que ESE usuario tiene de verdad, sin
          # importar el tipo.
          incluir_sysadmin? = socket.assigns.mostrar_sysadmin? and socket.assigns.current_scope.usuario.super_admin
          Permissions.listar_roles(empresa_id, incluir_sysadmin?)

        :por_usuario ->
          Permissions.roles_de_usuario(socket.assigns.usuario_seleccionado.id, empresa_id)
      end

    # Una Consulta Ecto es de solo lectura (ver moduledoc de
    # MetadataApp.MetaConsultas) — "crear"/"editar"/"eliminar" no tienen
    # ningún código que los consulte para este recurso (ni siquiera existe
    # un módulo Ecto real detrás, ver CatalogoController.resolver/1), así
    # que ni se ofrecen acá para no sugerir una capacidad que no existe.
    #
    # Un catálogo DETALLE: "eliminar" (DELETE /api/:tabla/:id) siempre
    # rechaza para un renglón — CatalogoGenerico.eliminar/2 tiene el
    # mensaje "los renglones de un catálogo detalle no se borran, use una
    # transición" hardcodeado. Conceder ese permiso ahí no habilita nada;
    # se saca del todo para no sugerir una capacidad que nunca funciona
    # (hallazgo 2026-08-03, ver docs/roadmap.md #15 — "editar" tiene el
    # mismo problema pero se deja por ahora, no se pidió tocarlo).
    acciones_crud =
      cond do
        socket.assigns.catalogo.es_consulta -> ~w(leer)
        socket.assigns.catalogo.es_detalle -> @acciones_crud -- ~w(eliminar)
        true -> @acciones_crud
      end
    acciones_transiciones = Enum.map(socket.assigns.transiciones, & &1.accion)
    acciones_todas = acciones_crud ++ acciones_transiciones
    rol_ids = Enum.map(roles, & &1.id)
    estado = Permissions.estado_permisos_para_roles(recurso, rol_ids, acciones_todas)
    alcance_por_rol = Permissions.alcance_de_catalogo(socket.assigns.catalogo.id)

    # "Alcance de datos por rol" para un rol SIN ningún permiso/transición
    # concedida en este catálogo no tiene nada que configurar todavía —
    # a pedido explícito, para que esa sección no se sature con roles que
    # todavía no pueden ni leer el catálogo. "administrador" siempre
    # queda (ve todo sin depender de @estado, mismo criterio que ya tenía
    # su fila fija arriba en la matriz de permisos).
    roles_con_permiso =
      Enum.filter(roles, fn rol ->
        rol.nombre == "administrador" or
          Enum.any?(acciones_todas, &Map.get(estado, {rol.id, &1}, %{concedido: false}).concedido)
      end)

    socket
    |> assign(:roles, roles)
    |> assign(:roles_con_permiso, roles_con_permiso)
    |> assign(:estado, estado)
    |> assign(:acciones_crud, acciones_crud)
    |> assign(:alcance_por_rol, alcance_por_rol)
  end

  def render(assigns) do
    ~H"""
    <div class={if @embebido?, do: "", else: "max-w-6xl mx-auto p-8"}>
      <div :if={!@embebido?} class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-2">
          <.link navigate={~p"/sysadmin/bc-list"} title="Volver al listado de BC"
            class="w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0">
            <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
          </.link>
          <h1 class="text-2xl font-bold">Bisness Context</h1>
        </div>
        <span :if={@catalogo} class="text-sm text-gray-500">
          <span class="font-semibold text-gray-700">BC:</span> {@catalogo.label}
        </span>
      </div>

      <div :if={@catalogo} class="mb-4 flex items-center gap-3">
        <div class="flex-1">
          <input
            type="text"
            value={@busqueda_usuario}
            phx-keyup="buscar_usuario"
            phx-debounce="200"
            placeholder="Por usuario (email)..."
            class="w-full border border-gray-300 rounded-lg px-4 py-2 text-sm text-gray-900"
          />
          <ul :if={@resultados_usuario != []} class="mt-1 border border-gray-200 rounded-lg divide-y divide-gray-100">
            <li :for={usuario <- @resultados_usuario} class="px-3 py-1.5">
              <button type="button" phx-click="elegir_usuario_filtro" phx-value-id={usuario.id} class="text-sm text-purple-700 hover:underline">
                {usuario.email}
              </button>
            </li>
          </ul>
        </div>
        <span class="text-xs text-gray-400">o</span>
        <button
          type="button"
          phx-click="ver_todos_los_roles"
          class={[
            "px-3 py-2 rounded-lg text-sm font-semibold border",
            if(@modo == :todos, do: "bg-purple-600 text-white border-purple-600", else: "bg-white text-gray-600 border-gray-300 hover:bg-gray-50")
          ]}
        >
          Todos los roles
        </button>
        <label
          :if={@current_scope.usuario.super_admin}
          class="flex items-center gap-1.5 text-xs font-medium text-gray-600 cursor-pointer select-none whitespace-nowrap"
        >
          <input
            type="checkbox"
            checked={@mostrar_sysadmin?}
            phx-click="toggle_mostrar_sysadmin"
            class="accent-purple-600"
          />
          Mostrar roles de Sysadmin
        </label>
      </div>

      <p :if={@modo == :por_usuario} class="text-sm text-gray-500 mb-4">
        Mostrando solo los roles de <strong class="text-gray-800">{@usuario_seleccionado.email}</strong>.
      </p>

      <div class={["grid grid-cols-1 gap-4", !@embebido? && "sm:grid-cols-[220px_1fr]"]}>
        <div :if={!@embebido?}>
          <input
            type="text"
            value={@busqueda_catalogo_picker}
            phx-keyup="buscar_catalogo_picker"
            phx-debounce="200"
            placeholder="Buscar catálogo..."
            class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-900 mb-2"
          />
          <ul class="border border-gray-200 rounded-lg divide-y divide-gray-100 max-h-96 overflow-y-auto">
            <li :for={c <- @resultados_catalogo_picker}>
              <button
                type="button"
                phx-click="elegir_catalogo"
                phx-value-recurso={c.recurso}
                class={[
                  "w-full text-left px-3 py-2 text-xs",
                  if(@catalogo && c.recurso == @catalogo.recurso, do: "bg-yellow-100 font-semibold text-gray-900", else: "text-gray-700 hover:bg-gray-50")
                ]}
              >
                {c.recurso}
              </button>
            </li>
            <li :if={@resultados_catalogo_picker == []} class="px-3 py-2 text-xs text-gray-400">
              Buscá un catálogo para empezar.
            </li>
          </ul>
        </div>

        <div :if={!@catalogo and !@embebido?} class="flex items-center justify-center rounded-xl border border-dashed border-gray-300 text-sm text-gray-400 p-12">
          Elegí un catálogo de la izquierda para ver y editar sus permisos.
        </div>

        <div :if={@catalogo} class="overflow-x-auto rounded-xl border border-gray-200">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-900">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-semibold text-white uppercase tracking-wide">Rol</th>
                <th class="px-4 py-3 text-left text-xs font-semibold text-white uppercase tracking-wide" colspan={length(@acciones_crud) + length(@transiciones)}>
                  Permisos y transiciones
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={rol <- @roles} class="hover:bg-purple-50/60">
                <td class="px-4 py-2 text-sm font-medium text-gray-900 whitespace-nowrap">
                  {rol.nombre}
                  <span :if={rol.nombre == "administrador"} class="ml-1 text-[10px] text-gray-400">(ve todo)</span>
                </td>
                <td class="px-4 py-2">
                  <div class="flex flex-wrap items-center gap-1">
                    <button
                      :if={rol.nombre != "administrador"}
                      type="button"
                      phx-click="conceder_todos"
                      phx-value-rol_id={rol.id}
                      class="text-[11px] text-purple-700 font-semibold hover:underline mr-1"
                    >
                      Todos
                    </button>
                    <button
                      :if={rol.nombre != "administrador"}
                      type="button"
                      phx-click="revocar_todos"
                      phx-value-rol_id={rol.id}
                      class="text-[11px] text-gray-500 hover:underline mr-2"
                    >
                      Ninguno
                    </button>
                    <button
                      :for={accion <- @acciones_crud}
                      type="button"
                      disabled={rol.nombre == "administrador"}
                      phx-click="toggle_permiso"
                      phx-value-rol_id={rol.id}
                      phx-value-accion={accion}
                      class={[
                        "px-2.5 py-1 rounded text-xs font-semibold border",
                        cond do
                          rol.nombre == "administrador" -> "bg-gray-100 text-gray-400 border-gray-200 cursor-not-allowed"
                          Map.get(@estado, {rol.id, accion}, %{concedido: false}).concedido -> "bg-purple-600 text-white border-purple-600"
                          true -> "bg-white text-gray-500 border-gray-300 hover:bg-gray-50"
                        end
                      ]}
                    >
                      {String.capitalize(accion)}
                    </button>
                    <button
                      :for={transicion <- @transiciones}
                      type="button"
                      disabled={rol.nombre == "administrador"}
                      phx-click="toggle_permiso"
                      phx-value-rol_id={rol.id}
                      phx-value-accion={transicion.accion}
                      title={"Acción: #{transicion.accion}"}
                      class={[
                        "px-2 py-0.5 rounded-full text-xs font-medium border",
                        cond do
                          rol.nombre == "administrador" -> "bg-gray-100 text-gray-400 border-gray-200 cursor-not-allowed"
                          Map.get(@estado, {rol.id, transicion.accion}, %{concedido: false}).concedido -> "bg-purple-600 text-white border-purple-600"
                          true -> "bg-white text-gray-500 border-gray-300 hover:bg-gray-50"
                        end
                      ]}
                    >
                      {transicion.etiqueta}
                    </button>
                  </div>
                </td>
              </tr>
              <tr :if={@roles == []}>
                <td colspan="2" class="px-4 py-6 text-center text-sm text-gray-400">
                  {if @modo == :por_usuario, do: "Este usuario no tiene ningún rol en esta empresa.", else: "Todavía no hay roles en esta empresa."}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div :if={@catalogo && @catalogo.es_consulta} class="mt-6 rounded-xl border border-gray-200 p-4 bg-gray-50">
        <h2 class="text-xs font-bold text-gray-700 uppercase tracking-wide">Alcance de datos</h2>
        <p class="text-[11px] text-gray-500 mt-0.5 max-w-2xl">
          Una Consulta no tiene Alcance de Datos propio — sigue el de su catálogo base,
          <span class="font-semibold">{@catalogo_base_de_consulta.label}</span>
          (<code class="font-mono">{@catalogo_base_de_consulta.nombre}</code>).
        </p>
        <p class="text-[11px] mt-2">
          <%= if @catalogo_base_de_consulta.alcance_habilitado do %>
            <span class="text-purple-700 font-semibold">✓ Activado</span> en el catálogo base — esta Consulta ya queda acotada igual.
          <% else %>
            <span class="text-gray-500">Sin activar</span> en el catálogo base — esta Consulta no filtra filas por alcance.
          <% end %>
          Para cambiarlo, ir a Permisos del catálogo base.
        </p>
      </div>

      <div :if={@catalogo && not @catalogo.es_consulta} class="mt-6 rounded-xl border border-gray-200 p-4">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h2 class="text-xs font-bold text-gray-700 uppercase tracking-wide">Alcance de datos</h2>
            <p class="text-[11px] text-gray-500 mt-0.5 max-w-2xl">
              Restringe QUÉ FILAS de este catálogo puede ver/operar cada usuario (propio/sucursal/unidad de ventas/ubicación de inventario/empresa/todas) — independiente de qué ACCIONES puede hacer (eso lo resuelve la tabla de arriba). Sin esto activado, el catálogo se comporta como siempre, sin ningún filtro nuevo.
            </p>
          </div>
          <button
            type="button"
            phx-click="toggle_alcance_habilitado"
            class={[
              "px-3 py-1.5 rounded-lg text-xs font-semibold border shrink-0",
              if(@catalogo.alcance_habilitado,
                do: "bg-purple-50 text-purple-700 border-purple-200",
                else: "bg-white text-gray-600 border-gray-300 hover:bg-gray-50"
              )
            ]}
          >
            {if @catalogo.alcance_habilitado, do: "✓ Alcance de datos — Quitar", else: "+ Alcance de datos"}
          </button>
        </div>
        <p :if={@alcance_error} class="text-[11px] text-red-600 mt-2">{@alcance_error}</p>
      </div>

      <.panel_alcance_de_rol :if={@catalogo && not @catalogo.es_consulta && @catalogo.alcance_habilitado}
        roles={@roles_con_permiso} alcance_por_rol={@alcance_por_rol} tipos_alcance={@tipos_alcance} />
    </div>
    """
  end

  # Fase 6 del modelo de Alcance de Datos (2026-08-11) — sección aparte,
  # NO otra columna de la matriz de arriba, a propósito: es un concepto
  # distinto (QUÉ FILAS, no QUÉ ACCIONES). Solo aparece si el catálogo ya
  # activó alcance_habilitado (toggle arriba, relocado 2026-08-12 desde
  # BcMotorLive/Get View), la mayoría de los catálogos hoy no lo tiene prendido.
  # `roles` acá es @roles_con_permiso (cargar_matriz/1), no @roles -- un rol
  # sin ningún permiso/transición concedida en este catálogo no tiene nada
  # que configurar todavía, a pedido explícito para no saturar esta lista.
  attr :roles, :list, required: true
  attr :alcance_por_rol, :map, required: true
  attr :tipos_alcance, :list, required: true

  defp panel_alcance_de_rol(assigns) do
    ~H"""
    <div class="mt-6 overflow-x-auto rounded-xl border border-gray-200">
      <div class="px-4 py-3 bg-gray-50 border-b border-gray-200">
        <h2 class="text-xs font-bold text-gray-700 uppercase tracking-wide">Alcance de datos por rol</h2>
        <p class="text-[11px] text-gray-500 mt-0.5">
          Qué filas de este catálogo puede ver/operar cada rol. Sin elegir nada, un rol queda en "Solo lo propio" (el más restrictivo) — "administrador" siempre ve todo, sin importar esto.
        </p>
      </div>

      <table class="min-w-full divide-y divide-gray-200">
        <tbody class="divide-y divide-gray-100">
          <tr :for={rol <- @roles} class="hover:bg-purple-50/60">
            <td class="px-4 py-2 text-sm font-medium text-gray-900 whitespace-nowrap">{rol.nombre}</td>
            <td class="px-4 py-2">
              <form id={"alcance-rol-#{rol.id}"} phx-change="cambiar_alcance_tipo">
                <input type="hidden" name="rol_id" value={rol.id} />
                <select
                  name="tipo"
                  disabled={rol.nombre == "administrador"}
                  class="text-xs border border-gray-300 rounded-lg px-2 py-1 disabled:bg-gray-100 disabled:text-gray-400"
                >
                  <option
                    :for={{etiqueta, valor} <- @tipos_alcance}
                    value={valor}
                    selected={Map.get(@alcance_por_rol, rol.id, :propio) == String.to_existing_atom(valor)}
                  >
                    {etiqueta}
                  </option>
                </select>
              </form>
            </td>
          </tr>
          <tr :if={@roles == []}>
            <td colspan="2" class="px-4 py-6 text-center text-sm text-gray-400">Ningún rol tiene permisos en este catálogo todavía — configuralos arriba primero.</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
