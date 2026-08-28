defmodule MetadataAppWeb.Sysadmin.AmbientesLive do
  @moduledoc """
  Administrador de "Ambientes de Deploy" (UI/ambientes-deploy, 2026-08-16)
  -- maestro-detalle, mismo criterio que CredencialesLive (de donde se
  copió el patrón entero: campos de secreto SIEMPRE write-only, ver
  Ambiente.changeset_edicion/2 -- dejar la contraseña/llave en blanco al
  editar NUNCA borra lo ya guardado, solo escribir algo nuevo lo
  reemplaza).

  El servidor de deploy vivía hardcodeado en 3 GitHub Actions secrets
  fijos (DEPLOY_HOST/DEPLOY_USER/DEPLOY_SSH_KEY) -- un solo ambiente
  posible. Acá se cargan tantos como haga falta; `mix motor.desplegar
  <nombre>` (ver lib/mix/tasks/motor.desplegar.ex) es quien realmente los
  usa al momento de desplegar, resolviendo la fila por nombre y
  conectando por SSH directo con SUS credenciales -- esta pantalla es
  pura configuración, no dispara ningún deploy por sí sola.
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_ambientes", "leer"}}

  alias MetadataApp.Ambientes
  alias MetadataApp.Ambientes.Ambiente
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
     |> assign(:current_page, "ambientes")
     |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> assign(:ambiente_seleccionado, nil)
     |> assign(:form, nil)
     |> cargar_ambientes()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "ambientes")
  end

  def handle_event("nuevo_ambiente", _params, socket) do
    {:noreply,
     socket
     |> assign(:ambiente_seleccionado, :nuevo)
     |> assign(:form, to_form(Ambiente.changeset_creacion(%Ambiente{}, %{})))}
  end

  def handle_event("seleccionar_ambiente", %{"id" => id}, socket) do
    ambiente = Enum.find(socket.assigns.ambientes, &(&1.id == String.to_integer(id)))

    {:noreply,
     socket
     |> assign(:ambiente_seleccionado, ambiente)
     |> assign(:form, to_form(Ambiente.changeset_edicion(ambiente, %{})))}
  end

  def handle_event("cerrar_detalle", _params, socket) do
    {:noreply, socket |> assign(:ambiente_seleccionado, nil) |> assign(:form, nil)}
  end

  def handle_event("validar_ambiente", %{"ambiente" => params}, socket) do
    changeset =
      case socket.assigns.ambiente_seleccionado do
        :nuevo -> Ambiente.changeset_creacion(%Ambiente{}, params)
        ambiente -> Ambiente.changeset_edicion(ambiente, params)
      end

    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("guardar_ambiente", %{"ambiente" => params}, socket) do
    resultado =
      case socket.assigns.ambiente_seleccionado do
        :nuevo -> Ambientes.crear_ambiente(params)
        ambiente -> Ambientes.actualizar_ambiente(ambiente, params)
      end

    case resultado do
      {:ok, ambiente} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ambiente \"#{ambiente.nombre}\" guardado.")
         |> assign(:ambiente_seleccionado, nil)
         |> assign(:form, nil)
         |> cargar_ambientes()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
    end
  end

  def handle_event("eliminar_ambiente", _params, socket) do
    case Ambientes.eliminar_ambiente(socket.assigns.ambiente_seleccionado) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ambiente eliminado.")
         |> assign(:ambiente_seleccionado, nil)
         |> assign(:form, nil)
         |> cargar_ambientes()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar el ambiente.")}
    end
  end

  defp cargar_ambientes(socket), do: assign(socket, :ambientes, Ambientes.listar_ambientes())

  def render(assigns) do
    ~H"""
    <div class="p-6">
      <div class="flex items-center gap-2 mb-4">
        <.link navigate={~p"/"} title="Volver al inicio"
          class="w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0">
          <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
        </.link>
        <div>
          <h1 class="text-2xl font-bold">Ambientes de Deploy</h1>
          <p class="text-xs text-gray-400">
            Servidores donde <code class="font-mono">mix motor.desplegar &lt;nombre&gt;</code> puede desplegar -- la contraseña/llave nunca se muestran de vuelta después de guardarlas.
          </p>
        </div>
      </div>

      <div class="flex gap-4 items-start">
        <div class="w-80 flex-shrink-0 border border-gray-200 rounded-xl overflow-hidden flex flex-col" style="height: 70vh">
          <div class="p-2 border-b border-gray-100">
            <button type="button" phx-click="nuevo_ambiente"
              class="w-full px-3 py-1.5 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
              + Nuevo ambiente
            </button>
          </div>

          <div class="flex-1 overflow-y-auto">
            <button
              :for={ambiente <- @ambientes}
              type="button"
              phx-click="seleccionar_ambiente"
              phx-value-id={ambiente.id}
              class={[
                "w-full text-left px-3 py-2 text-sm border-b border-gray-50 transition-colors",
                is_struct(@ambiente_seleccionado) && @ambiente_seleccionado.id == ambiente.id &&
                  "bg-purple-50 text-purple-700 font-semibold",
                !(is_struct(@ambiente_seleccionado) && @ambiente_seleccionado.id == ambiente.id) &&
                  "text-gray-700 hover:bg-gray-50"
              ]}
            >
              <div class="truncate">{ambiente.nombre}</div>
              <div class="text-[11px] text-gray-400 truncate font-mono">{ambiente.ssh_usuario}@{ambiente.host}</div>
            </button>

            <p :if={@ambientes == []} class="text-xs text-gray-400 p-3">Todavía no hay ambientes configurados.</p>
          </div>
        </div>

        <div class="flex-1 border border-gray-200 rounded-xl p-4" style="min-height: 70vh">
          <%= if @form do %>
            <div class="flex items-center justify-between mb-3">
              <h2 class="text-sm font-bold text-gray-900">
                {if @ambiente_seleccionado == :nuevo, do: "Nuevo ambiente", else: "Editar ambiente"}
              </h2>
              <button type="button" phx-click="cerrar_detalle" class="text-xs text-gray-500 hover:underline">Cerrar</button>
            </div>

            <.form for={@form} phx-change="validar_ambiente" phx-submit="guardar_ambiente" class="space-y-3 max-w-md">
              <div>
                <label class="block text-xs text-gray-500 mb-1">Nombre</label>
                <input type="text" name={@form[:nombre].name} value={@form[:nombre].value}
                  placeholder="produccion, staging, oficina..."
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm" required />
                <p :if={@form[:nombre].errors != []} class="text-[11px] text-red-600 mt-0.5">
                  {elem(hd(@form[:nombre].errors), 0)}
                </p>
              </div>

              <div>
                <label class="block text-xs text-gray-500 mb-1">Host</label>
                <input type="text" name={@form[:host].name} value={@form[:host].value}
                  placeholder="167.233.84.151 o dominio"
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono" required />
                <p :if={@form[:host].errors != []} class="text-[11px] text-red-600 mt-0.5">
                  {elem(hd(@form[:host].errors), 0)}
                </p>
              </div>

              <div>
                <label class="block text-xs text-gray-500 mb-1">Usuario SSH</label>
                <input type="text" name={@form[:ssh_usuario].name} value={@form[:ssh_usuario].value}
                  placeholder="elixir"
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono" required />
                <p :if={@form[:ssh_usuario].errors != []} class="text-[11px] text-red-600 mt-0.5">
                  {elem(hd(@form[:ssh_usuario].errors), 0)}
                </p>
              </div>

              <div>
                <label class="block text-xs text-gray-500 mb-1">
                  Contraseña SSH
                  <span :if={@ambiente_seleccionado != :nuevo} class="text-gray-400 font-normal">— dejar vacío para no cambiarla</span>
                </label>
                <input type="password" name={@form[:ssh_password_nuevo].name} value=""
                  autocomplete="new-password"
                  placeholder={if @ambiente_seleccionado == :nuevo, do: "Opcional si hay llave privada", else: "•••• (sin cambios)"}
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono" />
              </div>

              <div>
                <label class="block text-xs text-gray-500 mb-1">
                  Llave privada SSH
                  <span :if={@ambiente_seleccionado != :nuevo} class="text-gray-400 font-normal">— dejar vacío para no cambiarla</span>
                </label>
                <textarea name={@form[:ssh_llave_privada_nueva].name}
                  rows="3"
                  autocomplete="off"
                  placeholder={if @ambiente_seleccionado == :nuevo, do: "Opcional si hay contraseña -- pegar la llave privada (ed25519, etc.)", else: "•••• (sin cambios)"}
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-xs font-mono"
                ></textarea>
                <p :if={@form[:ssh_password_nuevo].errors != []} class="text-[11px] text-red-600 mt-0.5">
                  {elem(hd(@form[:ssh_password_nuevo].errors), 0)}
                </p>
              </div>

              <div>
                <label class="block text-xs text-gray-500 mb-1">Servicio Docker Swarm</label>
                <input type="text" name={@form[:docker_servicio].name} value={@form[:docker_servicio].value}
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono" required />
              </div>

              <div>
                <label class="block text-xs text-gray-500 mb-1">Imagen Docker</label>
                <input type="text" name={@form[:imagen_docker].name} value={@form[:imagen_docker].value}
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono" required />
              </div>

              <div class="flex justify-between items-center pt-2 border-t border-gray-100">
                <button
                  :if={is_struct(@ambiente_seleccionado)}
                  type="button"
                  phx-click="eliminar_ambiente"
                  data-confirm={"¿Eliminar el ambiente \"#{@ambiente_seleccionado.nombre}\"? mix motor.desplegar #{@ambiente_seleccionado.nombre} dejará de funcionar."}
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
            <p class="text-sm text-gray-400">Seleccioná un ambiente de la izquierda, o creá uno nuevo.</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
