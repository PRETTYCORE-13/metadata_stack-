defmodule MetadataAppWeb.Sysadmin.UsuariosEmpresaLive do
  @moduledoc """
  Quién pertenece a la empresa activa. Una sola acción ("Agregar") unifica
  sumar a alguien que ya tiene cuenta e invitar a alguien nuevo — no existe
  todavía un flujo de invitación por email separado, así que si la cuenta
  no existe se crea sola (sin contraseña, login por magic link como
  cualquier otra) en el mismo paso.
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
     |> assign(:current_page, "usuarios_empresa")
     |> assign(:menu_items, @menu)
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> assign(:nuevo_email, "")
     |> assign(:error_agregar, nil)
     |> cargar_usuarios()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "usuarios_empresa")
  end

  def handle_event("agregar_usuario", %{"email" => email}, socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id

    socket =
      case Autenticacion.agregar_usuario_a_empresa(email, empresa_id) do
        {:ok, _usuario} ->
          socket |> assign(nuevo_email: "", error_agregar: nil) |> cargar_usuarios()

        {:error, changeset} ->
          mensaje = changeset.errors |> Enum.map_join(", ", fn {campo, {msg, _}} -> "#{campo} #{msg}" end)
          assign(socket, :error_agregar, mensaje)
      end

    {:noreply, socket}
  end

  def handle_event("quitar_usuario", %{"id" => usuario_id}, socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id
    Autenticacion.remover_usuario_de_empresa(usuario_id, empresa_id)
    {:noreply, cargar_usuarios(socket)}
  end

  defp cargar_usuarios(socket) do
    empresa_id = socket.assigns.current_scope.empresa_activa.id
    assign(socket, :usuarios, Autenticacion.listar_usuarios_de_empresa(empresa_id))
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-8">
      <h1 class="text-2xl font-bold mb-1">Usuarios de la empresa</h1>
      <p class="text-sm text-gray-500 mb-6">
        {@current_scope.empresa_activa.nombre}
      </p>

      <form phx-submit="agregar_usuario" class="flex items-start gap-2 mb-6">
        <div class="flex-1">
          <input
            type="email"
            name="email"
            value={@nuevo_email}
            placeholder="email@ejemplo.com"
            required
            class="w-full border border-gray-300 rounded-lg px-4 py-2 text-sm text-gray-900"
          />
          <p :if={@error_agregar} class="text-xs text-red-600 mt-1">{@error_agregar}</p>
          <p :if={!@error_agregar} class="text-xs text-gray-400 mt-1">
            Si el email ya tiene cuenta, se agrega directo. Si no existe, se crea sola — puede iniciar sesión con ese email en cuanto quiera.
          </p>
        </div>
        <button
          type="submit"
          class="flex-shrink-0 bg-purple-600 hover:bg-purple-700 text-white font-bold px-4 py-2 rounded text-sm"
        >
          Agregar
        </button>
      </form>

      <div class="overflow-x-auto rounded-xl border border-gray-200">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Email</th>
              <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Cuenta</th>
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <tr :for={usuario <- @usuarios} class="hover:bg-purple-50/60">
              <td class="px-4 py-2 text-sm text-gray-900">{usuario.email}</td>
              <td class="px-4 py-2 text-sm">
                <span :if={usuario.confirmed_at} class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold bg-green-50 text-green-700 border border-green-100">
                  Confirmada
                </span>
                <span :if={!usuario.confirmed_at} class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold bg-amber-50 text-amber-700 border border-amber-100">
                  Sin confirmar
                </span>
              </td>
              <td class="px-4 py-2 text-right">
                <button
                  type="button"
                  phx-click="quitar_usuario"
                  phx-value-id={usuario.id}
                  data-confirm={"¿Quitar a #{usuario.email} de esta empresa? Pierde cualquier rol que tenga acá."}
                  class="text-xs text-red-600 hover:underline"
                >
                  Quitar
                </button>
              </td>
            </tr>
            <tr :if={@usuarios == []}>
              <td colspan="3" class="px-4 py-6 text-center text-sm text-gray-400">
                Todavía no hay usuarios en esta empresa.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
