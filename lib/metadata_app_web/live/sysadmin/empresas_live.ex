defmodule MetadataAppWeb.Sysadmin.EmpresasLive do
  @moduledoc """
  Empresas (tenants) a las que pertenece el usuario actual — listar,
  crear, renombrar. Crear una empresa te deja adentro como `administrador`
  automáticamente (ver `Autenticacion.crear_empresa_para_usuario/2`); no
  hay todavía un "super admin" cross-empresa, así que la lista acá es
  siempre "las mías", no todas las que existan en el sistema.
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"rbac_admin", "leer"}}

  alias MetadataApp.Autenticacion
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
     |> assign(:current_page, "empresas")
     |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> assign(:form_nueva_empresa, nil)
     |> assign(:error_form, nil)
     |> assign(:empresa_editando, nil)
     |> cargar_empresas()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "empresas")
  end

  def handle_event("abrir_form_nueva", _params, socket) do
    {:noreply, assign(socket, form_nueva_empresa: %{"nombre" => ""}, error_form: nil)}
  end

  def handle_event("cerrar_form_nueva", _params, socket) do
    {:noreply, assign(socket, form_nueva_empresa: nil, error_form: nil)}
  end

  def handle_event("crear_empresa", %{"empresa" => %{"nombre" => nombre}}, socket) do
    usuario_id = socket.assigns.current_scope.usuario.id

    case Autenticacion.crear_empresa_para_usuario(nombre, usuario_id) do
      {:ok, _empresa} ->
        {:noreply, socket |> assign(form_nueva_empresa: nil, error_form: nil) |> cargar_empresas()}

      {:error, changeset} ->
        mensaje = changeset.errors |> Enum.map_join(", ", fn {campo, {msg, _}} -> "#{campo} #{msg}" end)
        {:noreply, assign(socket, :error_form, mensaje)}
    end
  end

  def handle_event("abrir_editar", %{"id" => id}, socket) do
    empresa = Enum.find(socket.assigns.empresas, &(&1.id == String.to_integer(id)))
    {:noreply, assign(socket, empresa_editando: empresa, error_form: nil)}
  end

  def handle_event("cerrar_editar", _params, socket) do
    {:noreply, assign(socket, empresa_editando: nil, error_form: nil)}
  end

  def handle_event("guardar_empresa", %{"empresa" => attrs}, socket) do
    case Autenticacion.actualizar_empresa(socket.assigns.empresa_editando, attrs) do
      {:ok, _empresa} ->
        {:noreply, socket |> assign(empresa_editando: nil, error_form: nil) |> cargar_empresas()}

      {:error, changeset} ->
        mensaje = changeset.errors |> Enum.map_join(", ", fn {campo, {msg, _}} -> "#{campo} #{msg}" end)
        {:noreply, assign(socket, :error_form, mensaje)}
    end
  end

  defp cargar_empresas(socket) do
    usuario_id = socket.assigns.current_scope.usuario.id
    assign(socket, :empresas, Autenticacion.empresas_de_usuario(usuario_id))
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-8">
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">Empresas</h1>
        <button
          type="button"
          phx-click="abrir_form_nueva"
          class="bg-purple-600 hover:bg-purple-700 text-white font-bold px-4 py-2 rounded text-sm"
        >
          + Nueva empresa
        </button>
      </div>
      <p class="text-sm text-gray-500 mb-6">Las empresas a las que pertenecés — crear una te deja adentro como administrador.</p>

      <div class="overflow-x-auto rounded-xl border border-gray-200">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Nombre</th>
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <tr :for={empresa <- @empresas} class="hover:bg-purple-50/60">
              <td class="px-4 py-2 text-sm text-gray-900">
                {empresa.nombre}
                <span
                  :if={@current_scope.empresa_activa && @current_scope.empresa_activa.id == empresa.id}
                  class="ml-2 inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold bg-purple-50 text-purple-700 border border-purple-100"
                >
                  Activa
                </span>
              </td>
              <td class="px-4 py-2 text-right">
                <button type="button" phx-click="abrir_editar" phx-value-id={empresa.id} class="text-xs text-purple-700 hover:underline">
                  Renombrar
                </button>
              </td>
            </tr>
            <tr :if={@empresas == []}>
              <td colspan="2" class="px-4 py-6 text-center text-sm text-gray-400">
                Todavía no pertenecés a ninguna empresa.
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@form_nueva_empresa} class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
        <div class="bg-white rounded-xl shadow-lg max-w-sm w-full p-6">
          <h2 class="text-lg font-bold mb-4">Nueva empresa</h2>
          <form phx-submit="crear_empresa">
            <div class="mb-4">
              <label class="text-xs font-semibold text-gray-500">Nombre</label>
              <input
                type="text"
                name="empresa[nombre]"
                required
                class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-900"
              />
            </div>
            <p :if={@error_form} class="text-xs text-red-600 mb-3">{@error_form}</p>
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="cerrar_form_nueva" class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50">
                Cancelar
              </button>
              <button type="submit" class="px-4 py-2 rounded bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
                Crear
              </button>
            </div>
          </form>
        </div>
      </div>

      <div :if={@empresa_editando} class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
        <div class="bg-white rounded-xl shadow-lg max-w-sm w-full p-6">
          <h2 class="text-lg font-bold mb-4">Renombrar empresa</h2>
          <form phx-submit="guardar_empresa">
            <div class="mb-4">
              <label class="text-xs font-semibold text-gray-500">Nombre</label>
              <input
                type="text"
                name="empresa[nombre]"
                value={@empresa_editando.nombre}
                required
                class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-900"
              />
            </div>
            <p :if={@error_form} class="text-xs text-red-600 mb-3">{@error_form}</p>
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="cerrar_editar" class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50">
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
