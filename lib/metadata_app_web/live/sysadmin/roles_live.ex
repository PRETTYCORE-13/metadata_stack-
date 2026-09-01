defmodule MetadataAppWeb.Sysadmin.RolesLive do
  @moduledoc """
  Roles y usuarios (RBAC) — una sola pantalla, sin navegar a otra ruta
  para ver el detalle: a la izquierda la tabla de roles, a la derecha los
  usuarios del rol seleccionado (con buscador para agregar/quitar).

  La gestión de permisos por catálogo se mudó enteramente a Permission
  Sets (`CatalogoPermisosLive`) — acá solo CRUD de roles + su membresía de
  usuarios, para no duplicar el mismo trabajo en dos pantallas distintas.
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_roles", "leer"}}

  alias MetadataApp.Permissions
  alias MetadataAppWeb.AdminNav

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
  %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"}
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
     |> assign(:form_nuevo_rol, nil)
     |> assign(:error_nuevo_rol, nil)
     |> assign(:rol, nil)
     |> assign(:editando_rol, false)
     |> assign(:error_editar_rol, nil)
     |> assign(:busqueda_usuario, "")
     |> assign(:resultados_usuario, [])
     |> assign(:usuarios_del_rol, [])
     |> assign(:mostrar_sysadmin?, false)
     |> cargar_roles()}
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    case Permissions.obtener_rol(id) do
      {:ok, rol} ->
        # Cierra por URL directa el mismo hueco que el checkbox tapa en la
        # lista -- sin esto, alguien sin super_admin podía escribir
        # /sysadmin/roles/<id de un rol sysadmin> a mano y verlo igual,
        # aunque nunca apareciera en la tabla de la izquierda.
        if rol.tipo == :sysadmin and not socket.assigns.current_scope.usuario.super_admin do
          {:noreply,
           socket
           |> put_flash(:error, "Ese rol no existe.")
           |> push_patch(to: ~p"/sysadmin/roles")}
        else
          {:noreply,
           socket
           |> assign(:rol, rol)
           |> assign(:editando_rol, false)
           |> assign(:error_editar_rol, nil)
           |> assign(:busqueda_usuario, "")
           |> assign(:resultados_usuario, [])
           |> cargar_usuarios_del_rol()}
        end

      {:error, :no_encontrado} ->
        {:noreply,
         socket
         |> put_flash(:error, "Ese rol no existe.")
         |> push_patch(to: ~p"/sysadmin/roles")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :rol, nil)}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "roles")
  end

  # El checkbox ya está oculto en el render para cualquiera que no sea
  # super_admin (ver :if en la tabla) -- este chequeo server-side es
  # defensa en profundidad, mismo criterio que cambiar_empresa_en_foco/2
  # en UsuariosEmpresaLive: nunca confiar en que el cliente no mande el
  # evento igual.
  def handle_event("toggle_mostrar_sysadmin", _params, socket) do
    if socket.assigns.current_scope.usuario.super_admin do
      {:noreply, socket |> update(:mostrar_sysadmin?, &(!&1)) |> cargar_roles()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("seleccionar_rol", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/sysadmin/roles/#{id}")}
  end

  def handle_event("abrir_form_nuevo_rol", _params, socket) do
    {:noreply, assign(socket, form_nuevo_rol: %{"nombre" => "", "descripcion" => ""}, error_nuevo_rol: nil)}
  end

  def handle_event("cerrar_form_nuevo_rol", _params, socket) do
    {:noreply, assign(socket, form_nuevo_rol: nil, error_nuevo_rol: nil)}
  end

  def handle_event("crear_rol", %{"rol" => attrs}, socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id

    case Permissions.crear_rol(Map.put(attrs, "empresa_id", empresa_id)) do
      {:ok, rol} ->
        {:noreply,
         socket
         |> assign(form_nuevo_rol: nil, error_nuevo_rol: nil)
         |> cargar_roles()
         |> push_patch(to: ~p"/sysadmin/roles/#{rol.id}")}

      {:error, changeset} ->
        mensaje = changeset.errors |> Enum.map_join(", ", fn {campo, {msg, _}} -> "#{campo} #{msg}" end)
        {:noreply, assign(socket, error_nuevo_rol: mensaje)}
    end
  end

  def handle_event("eliminar_rol", %{"id" => id}, socket) do
    case Permissions.obtener_rol(id) do
      {:ok, rol} ->
        case Permissions.eliminar_rol(rol) do
          {:ok, _} ->
            socket = cargar_roles(socket)

            if socket.assigns.rol && to_string(socket.assigns.rol.id) == id do
              {:noreply, push_patch(socket, to: ~p"/sysadmin/roles")}
            else
              {:noreply, socket}
            end

          {:error, :rol_de_sistema} ->
            {:noreply, put_flash(socket, :error, "Los roles de sistema no se eliminan.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar el rol.")}
    end
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
        {:noreply, socket |> assign(rol: rol, editando_rol: false, error_editar_rol: nil) |> cargar_roles()}

      {:error, %Ecto.Changeset{} = changeset} ->
        mensaje = changeset.errors |> Enum.map_join(", ", fn {campo, {msg, _}} -> "#{campo} #{msg}" end)
        {:noreply, assign(socket, :error_editar_rol, mensaje)}

      {:error, :rol_de_sistema} ->
        {:noreply, assign(socket, :error_editar_rol, "Los roles de sistema no se editan.")}
    end
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

  defp cargar_roles(socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id
    # Segundo "and" server-side: aunque mostrar_sysadmin? ya solo se puede
    # prender vía toggle_mostrar_sysadmin/2 (que a su vez ya valida
    # super_admin), no cuesta nada no confiar en un solo lugar para esto.
    incluir_sysadmin? = socket.assigns.mostrar_sysadmin? and socket.assigns.current_scope.usuario.super_admin
    assign(socket, :roles, Permissions.listar_roles(empresa_id, incluir_sysadmin?))
  end

  defp cargar_usuarios_del_rol(socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id
    assign(socket, :usuarios_del_rol, Permissions.usuarios_del_rol(socket.assigns.rol.id, empresa_id))
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
          <h1 class="text-2xl font-bold">Roles y Usuarios</h1>
        </div>
        <div class="flex items-center gap-4">
          <label
            :if={@current_scope.usuario.super_admin}
            class="flex items-center gap-1.5 text-xs font-medium text-gray-600 cursor-pointer select-none"
          >
            <input
              type="checkbox"
              checked={@mostrar_sysadmin?}
              phx-click="toggle_mostrar_sysadmin"
              class="accent-purple-600"
            />
            Mostrar roles de Sysadmin
          </label>
          <button
            type="button"
            phx-click="abrir_form_nuevo_rol"
            class="pc-btn-secundario bg-linear-to-b from-white to-gray-100 hover:to-gray-200 border border-gray-100 text-gray-800 shadow-sm font-semibold text-xs px-4 py-1.5 rounded-full transition-colors"
          >
            + Nuevo rol
          </button>
        </div>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-[360px_1fr] gap-4 items-start">
        <!-- IZQUIERDA: tabla de roles -->
        <div class="overflow-x-auto rounded-xl border border-gray-200">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-3 py-2.5 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Nombre</th>
                <th class="px-3 py-2.5"></th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr
                :for={rol <- @roles}
                phx-click="seleccionar_rol"
                phx-value-id={rol.id}
                class={[
                  "cursor-pointer transition-colors",
                  if(@rol && @rol.id == rol.id, do: "bg-purple-50", else: "hover:bg-gray-50")
                ]}
              >
                <td class="px-3 py-2 text-sm">
                  <p class="font-semibold text-gray-900">{rol.nombre}</p>
                  <p :if={rol.descripcion} class="text-xs text-gray-500 truncate">{rol.descripcion}</p>
                  <span :if={rol.es_sistema} class="inline-flex items-center mt-1 px-2 py-0.5 rounded-full text-[10px] font-semibold bg-gray-100 text-gray-600 border border-gray-200">
                    Sistema
                  </span>
                  <span :if={!rol.es_sistema} class="inline-flex items-center mt-1 px-2 py-0.5 rounded-full text-[10px] font-semibold bg-purple-50 text-purple-700 border border-purple-100">
                    Propio
                  </span>
                </td>
                <td class="px-3 py-2 text-right align-top">
                  <button
                    :if={!rol.es_sistema}
                    type="button"
                    phx-click="eliminar_rol"
                    phx-value-id={rol.id}
                    data-confirm={"¿Eliminar el rol \"#{rol.nombre}\"?"}
                    class="text-xs text-red-600 hover:underline"
                  >
                    Eliminar
                  </button>
                </td>
              </tr>
              <tr :if={@roles == []}>
                <td colspan="2" class="px-3 py-6 text-center text-xs text-gray-400">Sin roles todavía.</td>
              </tr>
            </tbody>
          </table>
        </div>

        <!-- DERECHA: usuarios del rol seleccionado -->
        <div class="rounded-xl border border-gray-200 p-5 min-h-[20rem]">
          <%= if @rol do %>
            <div class="flex items-center gap-3 mb-1">
              <h2 class="text-xl font-bold">{@rol.nombre}</h2>
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
            <p :if={@rol.descripcion} class="text-sm text-gray-500 mb-4">{@rol.descripcion}</p>
            <div :if={!@rol.descripcion} class="mb-4"></div>

            <div :if={@rol.nombre == "administrador"} class="mb-4 rounded-lg bg-purple-50 border border-purple-100 px-4 py-3 text-sm text-purple-800">
              Este rol ve todos los permisos que existan automáticamente.
            </div>

            <h3 class="text-sm font-bold text-gray-500 uppercase tracking-wide mb-2">Usuarios con este rol</h3>

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
          <% else %>
            <div class="flex items-center justify-center h-full min-h-[18rem] text-sm text-gray-400 text-center px-8">
              Elegí un rol de la izquierda para ver y gestionar sus usuarios.
            </div>
          <% end %>
        </div>
      </div>

      <div :if={@form_nuevo_rol} class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
        <div class="bg-white rounded-xl shadow-lg max-w-sm w-full p-6">
          <h2 class="text-lg font-bold mb-4">Nuevo rol</h2>
          <form phx-submit="crear_rol">
            <div class="mb-3">
              <label class="text-xs font-semibold text-gray-500">Nombre</label>
              <input
                type="text"
                name="rol[nombre]"
                required
                class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-900"
              />
            </div>
            <div class="mb-4">
              <label class="text-xs font-semibold text-gray-500">Descripción</label>
              <input
                type="text"
                name="rol[descripcion]"
                class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-900"
              />
            </div>
            <p :if={@error_nuevo_rol} class="text-xs text-red-600 mb-3">{@error_nuevo_rol}</p>
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="cerrar_form_nuevo_rol" class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50">
                Cancelar
              </button>
              <button type="submit" class="px-4 py-2 rounded bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
                Crear
              </button>
            </div>
          </form>
        </div>
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
    </div>
    """
  end
end
