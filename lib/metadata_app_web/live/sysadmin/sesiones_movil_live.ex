defmodule MetadataAppWeb.Sysadmin.SesionesMovilLive do
  @moduledoc """
  Sesiones activas de la app Flutter del usuario logueado (SPEC-API-
  0409202601, R7) -- listar y revocar puntualmente (ej. teléfono
  perdido). A propósito SOLO requiere estar logueado (`on_mount
  :mount_current_scope`), sin la capacidad `sysadmin_*` que usan las
  demás pantallas de este menú -- es autoservicio sobre las PROPIAS
  sesiones de quien la abre, no una herramienta de administrar a otros
  usuarios (no hay selector de usuario acá, `listar_sesiones_movil/1`
  siempre corre contra `current_scope.usuario`). Vive bajo /sysadmin
  solo por ubicación de navegación -- no existe hoy ninguna pantalla de
  "mi perfil" separada (ver design.md §6).
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}

  alias MetadataApp.Autenticacion
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
    %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"},
    %{tipo: :pagina, id: "sesiones_movil", label: "Sesiones móviles", nav: "/sysadmin/sesiones-movil"}
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_page, "sesiones_movil")
     |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> cargar_sesiones()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "sesiones_movil")
  end

  def handle_event("revocar", %{"id" => id}, socket) do
    sesion = Enum.find(socket.assigns.sesiones, &(&1.id == String.to_integer(id)))

    case sesion && Autenticacion.revocar_sesion_movil(sesion) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Sesión cerrada -- ese dispositivo va a tener que loguearse de nuevo.")
         |> cargar_sesiones()}

      _ ->
        {:noreply, put_flash(socket, :error, "No se pudo cerrar esa sesión.")}
    end
  end

  defp cargar_sesiones(socket) do
    usuario = socket.assigns.current_scope.usuario
    assign(socket, :sesiones, Autenticacion.listar_sesiones_movil(usuario))
  end

  def render(assigns) do
    ~H"""
    <div class="p-6">
      <div class="flex items-center gap-2 mb-4">
        <.link navigate={~p"/"} title="Volver al inicio"
          class="w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0">
          <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
        </.link>
        <div>
          <h1 class="text-2xl font-bold">Sesiones móviles</h1>
          <p class="text-xs text-gray-400">
            Dispositivos donde tenés sesión abierta en la app -- cerrá cualquiera si perdiste el teléfono.
          </p>
        </div>
      </div>

      <div class="border border-gray-200 rounded-xl overflow-hidden max-w-2xl">
        <table class="w-full text-sm">
          <thead class="bg-gray-50 text-xs text-gray-500">
            <tr>
              <th class="text-left px-3 py-2">Dispositivo</th>
              <th class="text-left px-3 py-2">Creada</th>
              <th class="text-left px-3 py-2">Último uso</th>
              <th class="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={sesion <- @sesiones} class="border-t border-gray-100">
              <td class="px-3 py-2">{sesion.etiqueta_dispositivo || "Sesión sin nombre"}</td>
              <td class="px-3 py-2 text-gray-500">{Calendar.strftime(sesion.inserted_at, "%d/%m/%Y %H:%M")}</td>
              <td class="px-3 py-2 text-gray-500">
                {if sesion.ultimo_uso_en, do: Calendar.strftime(sesion.ultimo_uso_en, "%d/%m/%Y %H:%M"), else: "Nunca renovada"}
              </td>
              <td class="px-3 py-2 text-right">
                <button type="button" phx-click="revocar" phx-value-id={sesion.id}
                  data-confirm="¿Cerrar esta sesión? El dispositivo va a tener que loguearse de nuevo."
                  class="text-red-600 hover:text-red-800 text-xs font-semibold">
                  Cerrar sesión
                </button>
              </td>
            </tr>
            <tr :if={@sesiones == []}>
              <td colspan="4" class="px-3 py-6 text-center text-gray-400 text-sm">No hay sesiones móviles activas.</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
