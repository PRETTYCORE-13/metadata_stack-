defmodule MetadataAppWeb.Sysadmin.RolDetalleLive do
  @moduledoc """
  Detalle de un rol: qué catálogos puede leer/crear/editar/eliminar, y qué
  usuarios lo tienen. Diseñado para +1000 catálogos posibles — nunca se
  carga el universo completo de catálogos a memoria: el picker es un
  buscador server-side (`Permissions.buscar_catalogos/2`, tope 20 por
  búsqueda) que solo muestra/edita lo que matchea el texto tipeado, nunca
  una lista fija. Lo mismo para usuarios (acotado a la empresa activa).
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"rbac_admin", "leer"}}

  alias MetadataApp.Permissions
  alias MetadataAppWeb.AdminNav

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "roles", label: "Roles y Permisos", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"}
  ]

  @acciones ~w(leer crear editar eliminar)

  def mount(%{"id" => id}, _session, socket) do
    case Permissions.obtener_rol(id) do
      {:ok, rol} ->
        {:ok,
         socket
         |> assign(:current_page, "roles")
         |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
         |> assign(:sidebar_open, false)
         |> assign(:show_programacion_children, false)
         |> assign(:show_clientes_children, false)
         |> assign(:show_prettycore_children, false)
         |> assign(:rol, rol)
         |> assign(:acciones, @acciones)
         |> assign(:busqueda_catalogo, "")
         |> assign(:resultados_catalogo, [])
         |> assign(:busqueda_usuario, "")
         |> assign(:resultados_usuario, [])
         |> assign(:editando_rol, false)
         |> assign(:error_editar_rol, nil)
         |> cargar_usuarios_del_rol()}

      {:error, :no_encontrado} ->
        {:ok,
         socket
         |> put_flash(:error, "Ese rol no existe.")
         |> push_navigate(to: ~p"/sysadmin/roles")}
    end
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "roles")
  end

  def handle_event("abrir_editar_rol", _params, socket) do
    {:noreply, assign(socket, editando_rol: true, error_editar_rol: nil)}
  end

  def handle_event("cerrar_editar_rol", _params, socket) do
    {:noreply, assign(socket, editando_rol: false, error_editar_rol: nil)}
  end

  def handle_event("guardar_rol", %{"rol" => attrs}, socket) do
    case Permissions.actualizar_rol(socket.assigns.rol, attrs) do
      {:ok, rol} ->
        {:noreply, assign(socket, rol: rol, editando_rol: false, error_editar_rol: nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        mensaje = changeset.errors |> Enum.map_join(", ", fn {campo, {msg, _}} -> "#{campo} #{msg}" end)
        {:noreply, assign(socket, :error_editar_rol, mensaje)}

      {:error, :rol_de_sistema} ->
        {:noreply, assign(socket, :error_editar_rol, "Los roles de sistema no se editan.")}
    end
  end

  def handle_event("buscar_catalogo", %{"value" => texto}, socket) do
    resultados =
      texto
      |> Permissions.buscar_catalogos()
      |> anotar_estado_permisos(socket.assigns.rol.id)

    {:noreply, socket |> assign(:busqueda_catalogo, texto) |> assign(:resultados_catalogo, resultados)}
  end

  def handle_event("toggle_permiso", %{"recurso" => recurso, "accion" => accion}, socket) do
    rol_id = socket.assigns.rol.id
    estado = estado_actual(socket.assigns.resultados_catalogo, recurso, accion)

    if estado.concedido do
      Permissions.revocar_permiso_de_rol(rol_id, estado.permiso_id)
    else
      Permissions.conceder_permiso_catalogo(rol_id, recurso, accion)
    end

    resultados =
      socket.assigns.busqueda_catalogo
      |> Permissions.buscar_catalogos()
      |> anotar_estado_permisos(rol_id)

    {:noreply, assign(socket, :resultados_catalogo, resultados)}
  end

  def handle_event("buscar_usuario", %{"value" => texto}, socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id
    resultados = Permissions.buscar_usuarios_de_la_empresa(empresa_id, texto)
    {:noreply, socket |> assign(:busqueda_usuario, texto) |> assign(:resultados_usuario, resultados)}
  end

  def handle_event("asignar_usuario", %{"id" => usuario_id}, socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id
    rol_id = socket.assigns.rol.id

    socket =
      case Permissions.asignar_rol(usuario_id, rol_id, empresa_id) do
        {:ok, _} -> socket |> cargar_usuarios_del_rol() |> assign(busqueda_usuario: "", resultados_usuario: [])
        {:error, _} -> put_flash(socket, :error, "No se pudo asignar el rol.")
      end

    {:noreply, socket}
  end

  def handle_event("quitar_usuario", %{"id" => usuario_id}, socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id
    rol_id = socket.assigns.rol.id
    Permissions.revocar_rol(usuario_id, rol_id, empresa_id)
    {:noreply, cargar_usuarios_del_rol(socket)}
  end

  defp cargar_usuarios_del_rol(socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id
    assign(socket, :usuarios_del_rol, Permissions.usuarios_del_rol(socket.assigns.rol.id, empresa_id))
  end

  # Trae, en dos queries batch (nunca una por catálogo), tanto el estado de
  # los 4 permisos CRUD como el de las transiciones REALES de cada
  # catálogo — "guardar"/"aprobar"/etc. son un vocabulario abierto por
  # catálogo, no las 4 acciones fijas.
  defp anotar_estado_permisos(catalogos, rol_id) do
    recursos = Enum.map(catalogos, & &1.recurso)
    transiciones_por_catalogo = Permissions.transiciones_de_catalogos(recursos)

    pares_crud = for recurso <- recursos, accion <- @acciones, do: {recurso, accion}

    pares_transiciones =
      for {recurso, transiciones} <- transiciones_por_catalogo,
          %{accion: accion} <- transiciones,
          do: {recurso, accion}

    estado = Permissions.estado_permisos_para_pares(rol_id, pares_crud ++ pares_transiciones)

    Enum.map(catalogos, fn catalogo ->
      catalogo
      |> Map.put(:estado, estado)
      |> Map.put(:transiciones, Map.get(transiciones_por_catalogo, catalogo.recurso, []))
    end)
  end

  defp estado_actual(resultados, recurso, accion) do
    resultados
    |> Enum.find(&(&1.recurso == recurso))
    |> case do
      nil -> %{permiso_id: nil, concedido: false}
      catalogo -> Map.get(catalogo.estado, {recurso, accion}, %{permiso_id: nil, concedido: false})
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-8">
      <div class="mb-4">
        <.link navigate={~p"/sysadmin/roles"} class="text-sm text-purple-700 hover:underline">
          ← Roles
        </.link>
      </div>

      <div class="flex items-center gap-3 mb-1">
        <h1 class="text-2xl font-bold">{@rol.nombre}</h1>
        <span :if={@rol.es_sistema} class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold bg-gray-100 text-gray-600 border border-gray-200">
          Sistema
        </span>
        <button
          :if={!@rol.es_sistema}
          type="button"
          phx-click="abrir_editar_rol"
          class="text-xs text-purple-700 hover:underline"
        >
          Editar
        </button>
      </div>
      <p :if={@rol.descripcion} class="text-sm text-gray-500 mb-6">{@rol.descripcion}</p>
      <div :if={!@rol.descripcion} class="mb-6"></div>

      <div :if={@rol.nombre == "administrador"} class="mb-6 rounded-lg bg-purple-50 border border-purple-100 px-4 py-3 text-sm text-purple-800">
        Este rol ve todos los permisos que existan automáticamente — tocar los toggles de abajo no cambia su acceso real, pero puedes usarlos igual para ver qué transiciones tiene cada catálogo.
      </div>

      <div :if={@editando_rol} class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
        <div class="bg-white rounded-xl shadow-lg max-w-sm w-full p-6">
          <h2 class="text-lg font-bold mb-4">Editar rol</h2>
          <form phx-submit="guardar_rol">
            <div class="mb-3">
              <label class="text-xs font-semibold text-gray-500">Nombre</label>
              <input
                type="text"
                name="rol[nombre]"
                value={@rol.nombre}
                required
                class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-900"
              />
            </div>
            <div class="mb-4">
              <label class="text-xs font-semibold text-gray-500">Descripción</label>
              <input
                type="text"
                name="rol[descripcion]"
                value={@rol.descripcion}
                class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-900"
              />
            </div>
            <p :if={@error_editar_rol} class="text-xs text-red-600 mb-3">{@error_editar_rol}</p>
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="cerrar_editar_rol" class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50">
                Cancelar
              </button>
              <button type="submit" class="px-4 py-2 rounded bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
                Guardar
              </button>
            </div>
          </form>
        </div>
      </div>

      <div class="mb-8">
        <h2 class="text-sm font-bold text-gray-500 uppercase tracking-wide mb-2">Permisos por catálogo</h2>
        <input
          type="text"
          value={@busqueda_catalogo}
          phx-keyup="buscar_catalogo"
          phx-debounce="200"
          placeholder="Buscar catálogo por nombre..."
          class="w-full border border-gray-300 rounded-lg px-4 py-2 text-sm text-gray-900 mb-3"
        />

        <p :if={@busqueda_catalogo == ""} class="text-xs text-gray-400">
          Escribí para buscar entre los catálogos existentes.
        </p>

        <div :if={@busqueda_catalogo != "" and @resultados_catalogo == []} class="text-xs text-gray-400">
          Sin catálogos que coincidan con "{@busqueda_catalogo}".
        </div>

        <div :for={catalogo <- @resultados_catalogo} class="border-b border-gray-100 py-2">
          <div class="flex items-center justify-between">
            <div class="min-w-0">
              <p class="text-sm font-medium text-gray-900 truncate">{catalogo.label}</p>
              <p class="text-xs text-gray-400 font-mono truncate">
                {catalogo.recurso}
                <.link navigate={~p"/sysadmin/catalogos/#{catalogo.recurso}/permisos"} class="ml-2 text-purple-600 hover:underline">
                  ver todos los roles
                </.link>
              </p>
            </div>
            <div class="flex gap-1 flex-shrink-0">
              <button
                :for={accion <- @acciones}
                type="button"
                phx-click="toggle_permiso"
                phx-value-recurso={catalogo.recurso}
                phx-value-accion={accion}
                class={[
                  "px-2.5 py-1 rounded text-xs font-semibold border",
                  if(Map.get(catalogo.estado, {catalogo.recurso, accion}).concedido,
                    do: "bg-purple-600 text-white border-purple-600",
                    else: "bg-white text-gray-500 border-gray-300 hover:bg-gray-50"
                  )
                ]}
              >
                {String.capitalize(accion)}
              </button>
            </div>
          </div>

          <div :if={catalogo.transiciones != []} class="mt-2 pl-1 flex flex-wrap items-center gap-1">
            <span class="text-[10px] font-semibold text-gray-400 uppercase tracking-wide mr-1">Transiciones:</span>
            <button
              :for={transicion <- catalogo.transiciones}
              type="button"
              phx-click="toggle_permiso"
              phx-value-recurso={catalogo.recurso}
              phx-value-accion={transicion.accion}
              title={"Acción: #{transicion.accion}"}
              class={[
                "px-2 py-0.5 rounded-full text-xs font-medium border",
                if(Map.get(catalogo.estado, {catalogo.recurso, transicion.accion}).concedido,
                  do: "bg-purple-50 text-purple-700 border-purple-200",
                  else: "bg-white text-gray-500 border-gray-300 hover:bg-gray-50"
                )
              ]}
            >
              {transicion.etiqueta}
            </button>
          </div>
        </div>
      </div>

      <div>
        <h2 class="text-sm font-bold text-gray-500 uppercase tracking-wide mb-2">Usuarios con este rol</h2>

        <ul class="mb-4">
          <li :for={usuario <- @usuarios_del_rol} class="flex items-center justify-between border-b border-gray-100 py-2">
            <span class="text-sm text-gray-800">{usuario.email}</span>
            <button
              type="button"
              phx-click="quitar_usuario"
              phx-value-id={usuario.id}
              class="text-xs text-red-600 hover:underline"
            >
              Quitar
            </button>
          </li>
          <li :if={@usuarios_del_rol == []} class="text-xs text-gray-400 py-2">
            Ningún usuario tiene este rol todavía en esta empresa.
          </li>
        </ul>

        <input
          type="text"
          value={@busqueda_usuario}
          phx-keyup="buscar_usuario"
          phx-debounce="200"
          placeholder="Buscar usuario por email para agregarlo..."
          class="w-full border border-gray-300 rounded-lg px-4 py-2 text-sm text-gray-900 mb-2"
        />

        <ul :if={@resultados_usuario != []} class="border border-gray-200 rounded-lg divide-y divide-gray-100">
          <li :for={usuario <- @resultados_usuario} class="flex items-center justify-between px-3 py-2">
            <span class="text-sm text-gray-800">{usuario.email}</span>
            <button
              type="button"
              phx-click="asignar_usuario"
              phx-value-id={usuario.id}
              class="text-xs text-purple-700 font-semibold hover:underline"
            >
              Agregar
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
