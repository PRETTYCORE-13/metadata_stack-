defmodule MetadataAppWeb.Sysadmin.PanelControlLive do
  @moduledoc """
  "Panel Control" (Sysadmin, 2026-08-26) -- levantar una app nueva
  (dominio + deploy en k3s) para cualquier imagen Docker, no solo
  metadata_stack. Maestro-detalle, mismo esqueleto que AmbientesLive, pero
  sin modo edición: una vez creada, la app ya se desplegó (DNS + k3s +
  Caddy, ver MetadataApp.PanelControl.Desplegador) -- el detalle de una
  fila existente es de solo lectura (estado/nodeport/error), no un
  formulario para "corregir" un deploy que ya corrió.

  El deploy real (SSH + llamada a Hostinger) tarda de verdad (decenas de
  segundos) -- `start_async/3` para no bloquear el proceso LiveView
  mientras corre, con `@desplegando` deshabilitando el formulario mientras
  tanto.
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_panel_control", "leer"}}

  alias MetadataApp.{Ambientes, PanelControl}
  alias MetadataApp.PanelControl.{App, Desplegador}
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
     |> assign(:current_page, "panel_control")
     |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> assign(:app_seleccionada, nil)
     |> assign(:form, nil)
     |> assign(:desplegando, false)
     |> assign(:ambientes, Ambientes.listar_ambientes())
     |> cargar_apps()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "panel_control")
  end

  def handle_event("nueva_app", _params, socket) do
    {:noreply,
     socket
     |> assign(:app_seleccionada, :nuevo)
     |> assign(:form, to_form(App.changeset_creacion(%App{}, %{})))}
  end

  def handle_event("seleccionar_app", %{"id" => id}, socket) do
    app = Enum.find(socket.assigns.apps, &(&1.id == String.to_integer(id)))
    {:noreply, socket |> assign(:app_seleccionada, app) |> assign(:form, nil)}
  end

  def handle_event("cerrar_detalle", _params, socket) do
    {:noreply, socket |> assign(:app_seleccionada, nil) |> assign(:form, nil)}
  end

  def handle_event("validar_app", %{"app" => params}, socket) do
    changeset = App.changeset_creacion(%App{}, normalizar_params(params))
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("guardar_app", %{"app" => params}, socket) do
    case PanelControl.crear_app(normalizar_params(params)) do
      {:ok, app} ->
        {:noreply,
         socket
         |> assign(:desplegando, true)
         |> assign(:app_seleccionada, app)
         |> assign(:form, nil)
         |> cargar_apps()
         |> start_async(:desplegar_app, fn -> Desplegador.crear_app(app) end)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
    end
  end

  def handle_event("eliminar_app", _params, socket) do
    case PanelControl.eliminar_app(socket.assigns.app_seleccionada) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "App eliminada del panel (esto NO borra el deploy en k3s/Caddy/DNS -- hacelo a mano si hace falta).")
         |> assign(:app_seleccionada, nil)
         |> assign(:form, nil)
         |> cargar_apps()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar la app.")}
    end
  end

  def handle_async(:desplegar_app, {:ok, {:ok, app}}, socket) do
    mensaje =
      if app.estado == "activo" do
        {:info, "\"#{app.nombre}\" desplegada -- https://#{app.subdominio}.#{app.dominio_base}"}
      else
        {:error, "No se pudo desplegar \"#{app.nombre}\": #{app.ultimo_error}"}
      end

    {tipo, texto} = mensaje

    {:noreply,
     socket
     |> assign(:desplegando, false)
     |> assign(:app_seleccionada, app)
     |> put_flash(tipo, texto)
     |> cargar_apps()}
  end

  def handle_async(:desplegar_app, {:exit, razon}, socket) do
    {:noreply,
     socket
     |> assign(:desplegando, false)
     |> put_flash(:error, "El despliegue terminó de forma inesperada: #{inspect(razon)}")
     |> cargar_apps()}
  end

  # variables_entorno viaja como texto libre "CLAVE=valor" (una por línea)
  # en vez de un campo del schema -- App.changeset_creacion espera un
  # :map ahí, ningún input HTML plano arma eso solo.
  defp normalizar_params(params) do
    variables =
      params
      |> Map.get("variables_entorno_texto", "")
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Enum.filter(&match?([_clave, _valor], &1))
      |> Map.new(fn [clave, valor] -> {String.trim(clave), String.trim(valor)} end)

    Map.put(params, "variables_entorno", variables)
  end

  defp cargar_apps(socket), do: assign(socket, :apps, PanelControl.listar_apps())

  defp badge_estado(estado) do
    clase =
      case estado do
        "activo" -> "bg-green-100 text-green-700"
        "error" -> "bg-red-100 text-red-700"
        _ -> "bg-gray-100 text-gray-600"
      end

    {clase, estado}
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
          <h1 class="text-2xl font-bold">Panel Control</h1>
          <p class="text-xs text-gray-400">
            Levantar una app nueva: registra el subdominio en Hostinger, la despliega en k3s y la expone detrás de Caddy.
          </p>
        </div>
      </div>

      <div class="flex gap-4 items-start">
        <div class="w-80 flex-shrink-0 border border-gray-200 rounded-xl overflow-hidden flex flex-col" style="height: 70vh">
          <div class="p-2 border-b border-gray-100">
            <button type="button" phx-click="nueva_app"
              class="w-full px-3 py-1.5 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
              + Nueva app
            </button>
          </div>

          <div class="flex-1 overflow-y-auto">
            <button
              :for={app <- @apps}
              type="button"
              phx-click="seleccionar_app"
              phx-value-id={app.id}
              class={[
                "w-full text-left px-3 py-2 text-sm border-b border-gray-50 transition-colors",
                is_struct(@app_seleccionada) && @app_seleccionada.id == app.id &&
                  "bg-purple-50 text-purple-700 font-semibold",
                !(is_struct(@app_seleccionada) && @app_seleccionada.id == app.id) &&
                  "text-gray-700 hover:bg-gray-50"
              ]}
            >
              <div class="flex items-center justify-between gap-2">
                <span class="truncate">{app.nombre}</span>
                <span class={["text-[10px] px-1.5 py-0.5 rounded-full shrink-0", elem(badge_estado(app.estado), 0)]}>
                  {elem(badge_estado(app.estado), 1)}
                </span>
              </div>
              <div class="text-[11px] text-gray-400 truncate font-mono">{app.subdominio}.{app.dominio_base}</div>
            </button>

            <p :if={@apps == []} class="text-xs text-gray-400 p-3">Todavía no hay apps creadas.</p>
          </div>
        </div>

        <div class="flex-1 border border-gray-200 rounded-xl p-4" style="min-height: 70vh">
          <%= cond do %>
            <% @form -> %>
              <div class="flex items-center justify-between mb-3">
                <h2 class="text-sm font-bold text-gray-900">Nueva app</h2>
                <button type="button" phx-click="cerrar_detalle" class="text-xs text-gray-500 hover:underline">Cerrar</button>
              </div>

              <.form for={@form} phx-change="validar_app" phx-submit="guardar_app" class="space-y-3 max-w-md">
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Nombre</label>
                  <input type="text" name={@form[:nombre].name} value={@form[:nombre].value}
                    placeholder="Landing cliente X"
                    class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm" required />
                  <p :if={@form[:nombre].errors != []} class="text-[11px] text-red-600 mt-0.5">{elem(hd(@form[:nombre].errors), 0)}</p>
                </div>

                <div class="grid grid-cols-2 gap-2">
                  <div>
                    <label class="block text-xs text-gray-500 mb-1">Subdominio</label>
                    <input type="text" name={@form[:subdominio].name} value={@form[:subdominio].value}
                      placeholder="cliente-x"
                      class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono" required />
                    <p :if={@form[:subdominio].errors != []} class="text-[11px] text-red-600 mt-0.5">{elem(hd(@form[:subdominio].errors), 0)}</p>
                  </div>
                  <div>
                    <label class="block text-xs text-gray-500 mb-1">Dominio base</label>
                    <input type="text" name={@form[:dominio_base].name} value={@form[:dominio_base].value}
                      placeholder="ventaenruta.com.mx"
                      class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono" required />
                    <p :if={@form[:dominio_base].errors != []} class="text-[11px] text-red-600 mt-0.5">{elem(hd(@form[:dominio_base].errors), 0)}</p>
                  </div>
                </div>

                <div>
                  <label class="block text-xs text-gray-500 mb-1">Imagen Docker</label>
                  <input type="text" name={@form[:imagen_docker].name} value={@form[:imagen_docker].value}
                    placeholder="nginx:latest, ghcr.io/org/app:tag..."
                    class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono" required />
                  <p :if={@form[:imagen_docker].errors != []} class="text-[11px] text-red-600 mt-0.5">{elem(hd(@form[:imagen_docker].errors), 0)}</p>
                </div>

                <div>
                  <label class="block text-xs text-gray-500 mb-1">Puerto interno (el que escucha el contenedor)</label>
                  <input type="number" name={@form[:puerto_interno].name} value={@form[:puerto_interno].value}
                    placeholder="80, 3000, 8080..."
                    class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono" required />
                  <p :if={@form[:puerto_interno].errors != []} class="text-[11px] text-red-600 mt-0.5">{elem(hd(@form[:puerto_interno].errors), 0)}</p>
                </div>

                <div>
                  <label class="block text-xs text-gray-500 mb-1">Variables de entorno (una por línea, CLAVE=valor)</label>
                  <textarea name="app[variables_entorno_texto]" rows="4"
                    placeholder={"DATABASE_URL=postgres://...\nAPI_KEY=..."}
                    class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-xs font-mono"></textarea>
                </div>

                <div>
                  <label class="block text-xs text-gray-500 mb-1">Servidor de destino</label>
                  <select name={@form[:ambiente_id].name} class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm">
                    <option value="">Elegir ambiente...</option>
                    <option :for={ambiente <- @ambientes} value={ambiente.id} selected={to_string(@form[:ambiente_id].value) == to_string(ambiente.id)}>
                      {ambiente.nombre} ({ambiente.host})
                    </option>
                  </select>
                  <p :if={@form[:ambiente_id].errors != []} class="text-[11px] text-red-600 mt-0.5">{elem(hd(@form[:ambiente_id].errors), 0)}</p>
                  <p :if={@ambientes == []} class="text-[11px] text-amber-600 mt-0.5">No hay ningún ambiente configurado -- creá uno primero en /sysadmin/ambientes.</p>
                </div>

                <div class="flex justify-end pt-2 border-t border-gray-100">
                  <button type="submit" disabled={@desplegando}
                    class="px-4 py-1.5 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700 disabled:opacity-50">
                    {if @desplegando, do: "Desplegando...", else: "Crear y desplegar"}
                  </button>
                </div>
              </.form>

            <% is_struct(@app_seleccionada) -> %>
              <div class="flex items-center justify-between mb-3">
                <h2 class="text-sm font-bold text-gray-900">{@app_seleccionada.nombre}</h2>
                <button type="button" phx-click="cerrar_detalle" class="text-xs text-gray-500 hover:underline">Cerrar</button>
              </div>

              <dl class="space-y-2 text-sm max-w-md">
                <div class="flex justify-between border-b border-gray-50 pb-1">
                  <dt class="text-gray-500">Estado</dt>
                  <dd>
                    <span class={["text-[11px] px-2 py-0.5 rounded-full", elem(badge_estado(@app_seleccionada.estado), 0)]}>
                      {elem(badge_estado(@app_seleccionada.estado), 1)}
                    </span>
                  </dd>
                </div>
                <div class="flex justify-between border-b border-gray-50 pb-1">
                  <dt class="text-gray-500">URL</dt>
                  <dd class="font-mono text-xs">{@app_seleccionada.subdominio}.{@app_seleccionada.dominio_base}</dd>
                </div>
                <div class="flex justify-between border-b border-gray-50 pb-1">
                  <dt class="text-gray-500">Imagen</dt>
                  <dd class="font-mono text-xs">{@app_seleccionada.imagen_docker}</dd>
                </div>
                <div class="flex justify-between border-b border-gray-50 pb-1">
                  <dt class="text-gray-500">Puerto interno</dt>
                  <dd class="font-mono text-xs">{@app_seleccionada.puerto_interno}</dd>
                </div>
                <div :if={@app_seleccionada.nodeport} class="flex justify-between border-b border-gray-50 pb-1">
                  <dt class="text-gray-500">NodePort (k3s)</dt>
                  <dd class="font-mono text-xs">{@app_seleccionada.nodeport}</dd>
                </div>
                <div :if={@app_seleccionada.ultimo_error} class="pt-1">
                  <dt class="text-gray-500 mb-1">Último error</dt>
                  <dd class="text-xs text-red-600 font-mono whitespace-pre-wrap">{@app_seleccionada.ultimo_error}</dd>
                </div>
              </dl>

              <div class="pt-3 mt-3 border-t border-gray-100">
                <button type="button" phx-click="eliminar_app"
                  data-confirm={"¿Eliminar \"#{@app_seleccionada.nombre}\" del panel? Esto NO borra el deployment de k3s, el bloque de Caddy ni el registro DNS -- hacelo a mano si hace falta."}
                  class="text-red-600 hover:text-red-800 text-xs font-semibold">
                  Eliminar del panel
                </button>
              </div>

            <% true -> %>
              <p class="text-sm text-gray-400">Seleccioná una app de la izquierda, o creá una nueva.</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
