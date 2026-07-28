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
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"rbac_admin", "leer"}}

  alias MetadataApp.Permissions
  alias MetadataAppWeb.AdminNav

  @acciones_crud ~w(leer crear editar eliminar)

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"}
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_page, "roles")
     |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> assign(:acciones_crud, @acciones_crud)
     |> assign(:busqueda_catalogo_picker, "")
     |> assign(:resultados_catalogo_picker, [])
     |> assign(:modo, :todos)
     |> assign(:busqueda_usuario, "")
     |> assign(:resultados_usuario, [])
     |> assign(:usuario_seleccionado, nil)
     |> assign(:catalogo, nil)
     |> assign(:transiciones, [])
     |> assign(:roles, [])
     |> assign(:estado, %{})}
  end

  def handle_params(%{"recurso" => recurso}, _uri, socket) do
    case Permissions.obtener_catalogo(recurso) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Ese catálogo no existe.")
         |> push_patch(to: ~p"/sysadmin/catalogos/permisos")}

      catalogo ->
        {:noreply,
         socket
         |> assign(:catalogo, catalogo)
         |> assign(:transiciones, Permissions.transiciones_de_catalogos([recurso]) |> Map.get(recurso, []))
         |> cargar_matriz()}
    end
  end

  # Entrada directa "Permission Sets" del submenú (sin BC List de por
  # medio, que no existe en producción) — sin recurso todavía, solo el
  # buscador de la izquierda hasta que se elija uno.
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "roles")
  end

  def handle_event("buscar_catalogo_picker", %{"value" => texto}, socket) do
    resultados = Permissions.buscar_catalogos(texto)
    {:noreply, socket |> assign(:busqueda_catalogo_picker, texto) |> assign(:resultados_catalogo_picker, resultados)}
  end

  def handle_event("elegir_catalogo", %{"recurso" => recurso}, socket) do
    {:noreply, push_patch(socket, to: ~p"/sysadmin/catalogos/#{recurso}/permisos")}
  end

  def handle_event("ver_todos_los_roles", _params, socket) do
    {:noreply,
     socket
     |> assign(modo: :todos, usuario_seleccionado: nil, busqueda_usuario: "", resultados_usuario: [])
     |> cargar_matriz()}
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

  defp cargar_matriz(socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id
    recurso = socket.assigns.catalogo.recurso

    roles =
      case socket.assigns.modo do
        :todos -> Permissions.listar_roles(empresa_id)
        :por_usuario -> Permissions.roles_de_usuario(socket.assigns.usuario_seleccionado.id, empresa_id)
      end

    # Una Consulta Ecto es de solo lectura (ver moduledoc de
    # MetadataApp.MetaConsultas) — "crear"/"editar"/"eliminar" no tienen
    # ningún código que los consulte para este recurso (ni siquiera existe
    # un módulo Ecto real detrás, ver CatalogoController.resolver/1), así
    # que ni se ofrecen acá para no sugerir una capacidad que no existe.
    acciones_crud = if socket.assigns.catalogo.es_consulta, do: ~w(leer), else: @acciones_crud
    acciones_transiciones = Enum.map(socket.assigns.transiciones, & &1.accion)
    rol_ids = Enum.map(roles, & &1.id)
    estado = Permissions.estado_permisos_para_roles(recurso, rol_ids, acciones_crud ++ acciones_transiciones)

    socket |> assign(:roles, roles) |> assign(:estado, estado) |> assign(:acciones_crud, acciones_crud)
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-8">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-2">
          <.link navigate={~p"/"} title="Volver al inicio"
            class="w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0">
            <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
          </.link>
          <h1 class="text-2xl font-bold">Permission Sets</h1>
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
      </div>

      <p :if={@modo == :por_usuario} class="text-sm text-gray-500 mb-4">
        Mostrando solo los roles de <strong class="text-gray-800">{@usuario_seleccionado.email}</strong>.
      </p>

      <div class="grid grid-cols-[220px_1fr] gap-4">
        <div>
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

        <div :if={!@catalogo} class="flex items-center justify-center rounded-xl border border-dashed border-gray-300 text-sm text-gray-400 p-12">
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
                          Map.get(@estado, {rol.id, transicion.accion}, %{concedido: false}).concedido -> "bg-purple-50 text-purple-700 border-purple-200"
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
    </div>
    """
  end
end
