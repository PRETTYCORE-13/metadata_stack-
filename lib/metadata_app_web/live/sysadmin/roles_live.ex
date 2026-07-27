defmodule MetadataAppWeb.Sysadmin.RolesLive do
  @moduledoc """
  Administración de roles (RBAC, Fase 2 Paso 6b) — lista los roles de la
  empresa activa + los de sistema (inmutables). El detalle de permisos y
  usuarios de cada rol vive en `RolDetalleLive`, no acá: con +1000
  catálogos posibles, esta pantalla se queda liviana (solo roles, nunca
  catálogos) y el picker de catálogos vive en su propia pantalla con
  buscador server-side.
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
     |> cargar_roles()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "roles")
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
      {:ok, _rol} ->
        {:noreply, socket |> assign(form_nuevo_rol: nil, error_nuevo_rol: nil) |> cargar_roles()}

      {:error, changeset} ->
        mensaje = changeset.errors |> Enum.map_join(", ", fn {campo, {msg, _}} -> "#{campo} #{msg}" end)
        {:noreply, assign(socket, error_nuevo_rol: mensaje)}
    end
  end

  def handle_event("eliminar_rol", %{"id" => id}, socket) do
    socket =
      with {:ok, rol} <- Permissions.obtener_rol(id),
           {:ok, _} <- Permissions.eliminar_rol(rol) do
        cargar_roles(socket)
      else
        {:error, :rol_de_sistema} ->
          put_flash(socket, :error, "Los roles de sistema no se eliminan.")

        _ ->
          put_flash(socket, :error, "No se pudo eliminar el rol.")
      end

    {:noreply, socket}
  end

  defp cargar_roles(socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id
    assign(socket, :roles, Permissions.listar_roles(empresa_id))
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-8">
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">Roles y Permisos</h1>
        <button
          type="button"
          phx-click="abrir_form_nuevo_rol"
          class="bg-purple-600 hover:bg-purple-700 text-white font-bold px-4 py-2 rounded text-sm"
        >
          + Nuevo rol
        </button>
      </div>

      <div class="overflow-x-auto rounded-xl border border-gray-200">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Nombre</th>
              <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Descripción</th>
              <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Tipo</th>
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <tr :for={rol <- @roles} class="hover:bg-purple-50/60">
              <td class="px-4 py-2 text-sm">
                <.link navigate={~p"/sysadmin/roles/#{rol.id}"} class="text-purple-700 font-semibold hover:underline">
                  {rol.nombre}
                </.link>
              </td>
              <td class="px-4 py-2 text-sm text-gray-600">{rol.descripcion}</td>
              <td class="px-4 py-2 text-sm">
                <span :if={rol.es_sistema} class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold bg-gray-100 text-gray-600 border border-gray-200">
                  Sistema
                </span>
                <span :if={!rol.es_sistema} class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold bg-purple-50 text-purple-700 border border-purple-100">
                  Propio
                </span>
              </td>
              <td class="px-4 py-2 text-right">
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
          </tbody>
        </table>
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
    </div>
    """
  end
end
