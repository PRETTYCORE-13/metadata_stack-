defmodule MetadataAppWeb.Sysadmin.CredencialesLive do
  @moduledoc """
  Administrador de credenciales de sistemas externos (Fase 2 de
  "Integraciones", 2026-08-07) — maestro-detalle, mismo criterio que
  UsuariosEmpresaLive. El campo de la API key es SIEMPRE write-only: el
  formulario nunca la precarga con el valor real (ver
  Credencial.changeset_edicion/2) — dejarlo en blanco al editar no borra
  la key ya guardada, solo escribir algo nuevo la reemplaza.
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_credenciales", "leer"}}

  alias MetadataApp.Integraciones
  alias MetadataApp.Integraciones.Credencial
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
     |> assign(:current_page, "credenciales")
     |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> assign(:credencial_seleccionada, nil)
     |> assign(:form, nil)
     |> cargar_credenciales()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "credenciales")
  end

  def handle_event("nueva_credencial", _params, socket) do
    {:noreply,
     socket
     |> assign(:credencial_seleccionada, :nueva)
     |> assign(:form, to_form(Credencial.changeset_creacion(%Credencial{}, %{})))}
  end

  def handle_event("seleccionar_credencial", %{"id" => id}, socket) do
    credencial = Enum.find(socket.assigns.credenciales, &(&1.id == String.to_integer(id)))

    {:noreply,
     socket
     |> assign(:credencial_seleccionada, credencial)
     |> assign(:form, to_form(Credencial.changeset_edicion(credencial, %{})))}
  end

  def handle_event("cerrar_detalle", _params, socket) do
    {:noreply, socket |> assign(:credencial_seleccionada, nil) |> assign(:form, nil)}
  end

  def handle_event("validar_credencial", %{"credencial" => params}, socket) do
    changeset =
      case socket.assigns.credencial_seleccionada do
        :nueva -> Credencial.changeset_creacion(%Credencial{}, params)
        credencial -> Credencial.changeset_edicion(credencial, params)
      end

    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("guardar_credencial", %{"credencial" => params}, socket) do
    resultado =
      case socket.assigns.credencial_seleccionada do
        :nueva -> Integraciones.crear_credencial(params)
        credencial -> Integraciones.actualizar_credencial(credencial, params)
      end

    case resultado do
      {:ok, credencial} ->
        {:noreply,
         socket
         |> put_flash(:info, "Credencial \"#{credencial.nombre}\" guardada.")
         |> assign(:credencial_seleccionada, nil)
         |> assign(:form, nil)
         |> cargar_credenciales()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
    end
  end

  def handle_event("eliminar_credencial", _params, socket) do
    case Integraciones.eliminar_credencial(socket.assigns.credencial_seleccionada) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Credencial eliminada.")
         |> assign(:credencial_seleccionada, nil)
         |> assign(:form, nil)
         |> cargar_credenciales()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar la credencial.")}
    end
  end

  # Fase 8 ("Integraciones") -- resumen_7d en cada fila, mismo criterio de
  # "adjuntar" un campo calculado sobre el struct que ya usa BcListLive
  # (adjuntar_puede_desplegar/1) -- el badge de la lista responde "¿esta
  # credencial anda fallando?" sin tener que entrar a cada una.
  defp cargar_credenciales(socket) do
    credenciales =
      Integraciones.listar_credenciales()
      |> Enum.map(&Map.put(&1, :resumen_7d, Integraciones.resumen_ejecuciones(&1.id)))

    assign(socket, :credenciales, credenciales)
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
          <h1 class="text-2xl font-bold">Credenciales</h1>
          <p class="text-xs text-gray-400">Claves de sistemas externos — la key nunca se muestra de vuelta después de guardarla.</p>
        </div>
      </div>

      <div class="flex gap-4 items-start">
        <div class="w-80 flex-shrink-0 border border-gray-200 rounded-xl overflow-hidden flex flex-col" style="height: 70vh">
          <div class="p-2 border-b border-gray-100">
            <button type="button" phx-click="nueva_credencial"
              class="w-full px-3 py-1.5 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
              + Nueva credencial
            </button>
          </div>

          <div class="flex-1 overflow-y-auto">
            <button
              :for={credencial <- @credenciales}
              type="button"
              phx-click="seleccionar_credencial"
              phx-value-id={credencial.id}
              class={[
                "w-full text-left px-3 py-2 text-sm border-b border-gray-50 transition-colors",
                is_struct(@credencial_seleccionada) && @credencial_seleccionada.id == credencial.id &&
                  "bg-purple-50 text-purple-700 font-semibold",
                !(is_struct(@credencial_seleccionada) && @credencial_seleccionada.id == credencial.id) &&
                  "text-gray-700 hover:bg-gray-50"
              ]}
            >
              <div class="flex items-center justify-between gap-2">
                <span class="truncate">{credencial.nombre}</span>
                <span :if={credencial.ultimo_error} class="w-2 h-2 rounded-full bg-red-500 shrink-0" title={"Última falla: #{credencial.ultimo_error}"}></span>
              </div>
              <div class="flex items-center justify-between gap-2">
                <span class="text-[11px] text-gray-400 truncate">{credencial.sistema_externo}</span>
                <span :if={credencial.resumen_7d.total > 0} class={[
                  "text-[10px] font-mono shrink-0",
                  credencial.resumen_7d.errores > 0 && "text-red-500",
                  credencial.resumen_7d.errores == 0 && "text-gray-400"
                ]}>
                  {credencial.resumen_7d.total - credencial.resumen_7d.errores}/{credencial.resumen_7d.total} ok (7d)
                </span>
              </div>
            </button>

            <p :if={@credenciales == []} class="text-xs text-gray-400 p-3">Todavía no hay credenciales.</p>
          </div>
        </div>

        <div class="flex-1 border border-gray-200 rounded-xl p-4" style="min-height: 70vh">
          <%= if @form do %>
            <div class="flex items-center justify-between mb-3">
              <h2 class="text-sm font-bold text-gray-900">
                {if @credencial_seleccionada == :nueva, do: "Nueva credencial", else: "Editar credencial"}
              </h2>
              <button type="button" phx-click="cerrar_detalle" class="text-xs text-gray-500 hover:underline">Cerrar</button>
            </div>

            <.form for={@form} phx-change="validar_credencial" phx-submit="guardar_credencial" class="space-y-3 max-w-md">
              <div>
                <label class="block text-xs text-gray-500 mb-1">Nombre</label>
                <input type="text" name={@form[:nombre].name} value={@form[:nombre].value}
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm" required />
                <p :if={@form[:nombre].errors != []} class="text-[11px] text-red-600 mt-0.5">
                  {elem(hd(@form[:nombre].errors), 0)}
                </p>
              </div>

              <div>
                <label class="block text-xs text-gray-500 mb-1">Sistema externo</label>
                <input type="text" name={@form[:sistema_externo].name} value={@form[:sistema_externo].value}
                  placeholder="stripe, sat, crm-interno..."
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm" />
              </div>

              <div>
                <label class="block text-xs text-gray-500 mb-1">Base URL</label>
                <input type="text" name={@form[:base_url].name} value={@form[:base_url].value}
                  placeholder="https://api.ejemplo.com"
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm" />
              </div>

              <div>
                <label class="block text-xs text-gray-500 mb-1">
                  API Key
                  <span :if={@credencial_seleccionada != :nueva} class="text-gray-400 font-normal">— dejar vacío para no cambiarla</span>
                </label>
                <input type="password" name={@form[:api_key_nuevo].name} value=""
                  autocomplete="new-password"
                  placeholder={if @credencial_seleccionada == :nueva, do: "Pegar la key aquí", else: "•••• (sin cambios)"}
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono" />
                <p :if={@form[:api_key_nuevo].errors != []} class="text-[11px] text-red-600 mt-0.5">
                  {elem(hd(@form[:api_key_nuevo].errors), 0)}
                </p>
              </div>

              <div :if={is_struct(@credencial_seleccionada)} class="text-[11px] text-gray-400 border-t border-gray-100 pt-2">
                <p :if={@credencial_seleccionada.ultima_ejecucion_en}>
                  Última ejecución: {@credencial_seleccionada.ultima_ejecucion_en}
                </p>
                <p :if={@credencial_seleccionada.ultimo_error} class="text-red-600">
                  Último error: {@credencial_seleccionada.ultimo_error}
                </p>
              </div>

              <div class="flex justify-between items-center pt-2 border-t border-gray-100">
                <button
                  :if={is_struct(@credencial_seleccionada)}
                  type="button"
                  phx-click="eliminar_credencial"
                  data-confirm={"¿Eliminar la credencial \"#{@credencial_seleccionada.nombre}\"? Cualquier acción que la use dejará de funcionar."}
                  class="text-red-600 hover:text-red-800 text-xs font-semibold"
                >
                  Eliminar
                </button>
                <span></span>
                <button type="submit" class="px-4 py-1.5 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
                  Guardar
                </button>
              </div>
            </.form>
          <% else %>
            <p class="text-sm text-gray-400">Seleccioná una credencial de la izquierda, o creá una nueva.</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
