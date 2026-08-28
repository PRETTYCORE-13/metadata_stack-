defmodule MetadataAppWeb.Sysadmin.AccionesExternasLive do
  @moduledoc """
  Administrador de Acciones externas (Fase 6 de "Integraciones",
  2026-08-07) — maestro-detalle, mismo patrón que CredencialesLive. Una
  acción es la config de UNA llamada HTTP reusable (método + url_template
  con placeholders `{campo}`/`{api_key}`/`{base_url}` — ver
  CatalogoGenerico.sustituir_variables/2 e Integraciones.ejecutar_accion/4)
  atada a una credencial (obligatoria) y, opcionalmente, a un catálogo — si
  tiene catálogo, FichaLive la ofrece como botón en la Ficha 360° de ese
  catálogo (ver FichaLive."ejecutar_accion_externa").

  `headers_template` es un `:map` en el schema pero HTML no tiene un input
  nativo para eso -- se edita acá como JSON en un textarea y se decodifica
  ANTES de llegar al changeset (ver `parsear_headers/1`).
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_acciones_externas", "leer"}}

  alias MetadataApp.Integraciones
  alias MetadataApp.Integraciones.AccionExterna
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
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
    %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"}
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_page, "acciones_externas")
     |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> assign(:accion_seleccionada, nil)
     |> assign(:form, nil)
     |> assign(:headers_template_texto, "")
     |> assign(:log, [])
     |> assign(:credenciales, Integraciones.listar_credenciales())
     |> assign(:catalogos, catalogos_para_combo())
     |> cargar_acciones()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "acciones_externas")
  end

  def handle_event("nueva_accion", _params, socket) do
    {:noreply,
     socket
     |> assign(:accion_seleccionada, :nueva)
     |> assign(:headers_template_texto, "")
     |> assign(:log, [])
     |> assign(:form, to_form(AccionExterna.changeset(%AccionExterna{}, %{})))}
  end

  def handle_event("seleccionar_accion", %{"id" => id}, socket) do
    accion = Enum.find(socket.assigns.acciones, &(&1.id == String.to_integer(id)))

    {:noreply,
     socket
     |> assign(:accion_seleccionada, accion)
     |> assign(:headers_template_texto, headers_a_texto(accion.headers_template))
     |> assign(:form, to_form(AccionExterna.changeset(accion, %{})))
     |> assign(:log, Integraciones.listar_log(accion.id))}
  end

  def handle_event("cerrar_detalle", _params, socket) do
    {:noreply, socket |> assign(:accion_seleccionada, nil) |> assign(:form, nil) |> assign(:log, [])}
  end

  def handle_event("validar_accion", %{"accion_externa" => params} = todos_params, socket) do
    headers_texto = Map.get(todos_params, "headers_template_texto", "")

    changeset =
      socket.assigns.accion_seleccionada
      |> accion_base()
      |> AccionExterna.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:headers_template_texto, headers_texto)
     |> assign(:form, to_form(changeset, action: :validate))}
  end

  def handle_event("guardar_accion", %{"accion_externa" => params} = todos_params, socket) do
    headers_texto = Map.get(todos_params, "headers_template_texto", "")

    case parsear_headers(headers_texto) do
      {:error, motivo} ->
        changeset =
          socket.assigns.accion_seleccionada
          |> accion_base()
          |> AccionExterna.changeset(params)
          |> Ecto.Changeset.add_error(:headers_template, "JSON inválido: #{motivo}")
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}

      {:ok, headers_map} ->
        params = Map.put(params, "headers_template", headers_map)

        resultado =
          case socket.assigns.accion_seleccionada do
            :nueva -> Integraciones.crear_accion(params)
            accion -> Integraciones.actualizar_accion(accion, params)
          end

        case resultado do
          {:ok, accion} ->
            {:noreply,
             socket
             |> put_flash(:info, "Acción \"#{accion.nombre}\" guardada.")
             |> assign(:accion_seleccionada, nil)
             |> assign(:form, nil)
             |> cargar_acciones()}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
        end
    end
  end

  def handle_event("eliminar_accion", _params, socket) do
    case Integraciones.eliminar_accion(socket.assigns.accion_seleccionada) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Acción eliminada.")
         |> assign(:accion_seleccionada, nil)
         |> assign(:form, nil)
         |> cargar_acciones()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar la acción.")}
    end
  end

  defp accion_base(:nueva), do: %AccionExterna{}
  defp accion_base(accion), do: accion

  defp cargar_acciones(socket), do: assign(socket, :acciones, Integraciones.listar_todas_acciones())

  # Excluye carpetas (schema_context_type == 2) -- mismo criterio que
  # MetaSchemaContext.buscar_catalogos_raiz/2. Sin acotar por
  # schema_encabezado_id: una acción también puede tener sentido en un
  # catálogo detalle (botón en la tabla de renglones, no solo el maestro).
  defp catalogos_para_combo do
    MetaSchemaContext.listar_headers()
    |> Enum.reject(&(&1.schema_context_type == 2))
    |> Enum.map(&{&1.schema_context_label, &1.id})
  end

  defp headers_a_texto(nil), do: ""
  defp headers_a_texto(map) when map_size(map) == 0, do: ""
  defp headers_a_texto(map), do: Jason.encode!(map, pretty: true)

  defp parsear_headers(""), do: {:ok, %{}}
  defp parsear_headers(nil), do: {:ok, %{}}

  defp parsear_headers(texto) do
    case Jason.decode(texto) do
      {:ok, mapa} when is_map(mapa) -> {:ok, mapa}
      {:ok, _} -> {:error, "tiene que ser un objeto, ej. {\"Authorization\": \"Bearer {api_key}\"}"}
      {:error, %Jason.DecodeError{} = e} -> {:error, Exception.message(e)}
    end
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
          <h1 class="text-2xl font-bold">Acciones externas</h1>
          <p class="text-xs text-gray-400">Llamadas HTTP configurables — atadas a una credencial y, opcional, a un catálogo (botón en su Ficha 360°).</p>
        </div>
      </div>

      <div class="flex gap-4 items-start">
        <div class="w-80 flex-shrink-0 border border-gray-200 rounded-xl overflow-hidden flex flex-col" style="height: 70vh">
          <div class="p-2 border-b border-gray-100">
            <button type="button" phx-click="nueva_accion"
              disabled={@credenciales == []}
              title={if @credenciales == [], do: "Primero creá al menos una credencial", else: nil}
              class="w-full px-3 py-1.5 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700 disabled:opacity-40 disabled:cursor-not-allowed">
              + Nueva acción
            </button>
          </div>

          <div class="flex-1 overflow-y-auto">
            <button
              :for={accion <- @acciones}
              type="button"
              phx-click="seleccionar_accion"
              phx-value-id={accion.id}
              class={[
                "w-full text-left px-3 py-2 text-sm border-b border-gray-50 transition-colors",
                is_struct(@accion_seleccionada) && @accion_seleccionada.id == accion.id &&
                  "bg-purple-50 text-purple-700 font-semibold",
                !(is_struct(@accion_seleccionada) && @accion_seleccionada.id == accion.id) &&
                  "text-gray-700 hover:bg-gray-50"
              ]}
            >
              <div class="flex items-center justify-between gap-2">
                <span class="truncate">{accion.etiqueta || accion.nombre}</span>
                <span class="text-[10px] font-mono text-gray-400 shrink-0">{accion.metodo}</span>
              </div>
              <div class="text-[11px] text-gray-400 truncate">
                {if accion.header, do: accion.header.schema_context_label, else: "standalone"} · {accion.credencial.nombre}
              </div>
            </button>

            <p :if={@acciones == []} class="text-xs text-gray-400 p-3">Todavía no hay acciones externas.</p>
          </div>
        </div>

        <div class="flex-1 border border-gray-200 rounded-xl p-4" style="min-height: 70vh">
          <%= if @form do %>
            <div class="flex items-center justify-between mb-3">
              <h2 class="text-sm font-bold text-gray-900">
                {if @accion_seleccionada == :nueva, do: "Nueva acción", else: "Editar acción"}
              </h2>
              <button type="button" phx-click="cerrar_detalle" class="text-xs text-gray-500 hover:underline">Cerrar</button>
            </div>

            <.form for={@form} phx-change="validar_accion" phx-submit="guardar_accion" class="space-y-3 max-w-lg">

              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Nombre (código, sin espacios)</label>
                  <input type="text" name={@form[:nombre].name} value={@form[:nombre].value}
                    placeholder="validar_credito"
                    class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono" required />
                  <p :if={@form[:nombre].errors != []} class="text-[11px] text-red-600 mt-0.5">{elem(hd(@form[:nombre].errors), 0)}</p>
                </div>

                <div>
                  <label class="block text-xs text-gray-500 mb-1">Etiqueta (texto del botón)</label>
                  <input type="text" name={@form[:etiqueta].name} value={@form[:etiqueta].value}
                    placeholder="Validar crédito"
                    class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm" />
                </div>
              </div>

              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Catálogo (opcional — vacío = standalone)</label>
                  <select name={@form[:meta_schema_header_id].name}
                    class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm">
                    <option value="">— ninguno —</option>
                    <option :for={{label, id} <- @catalogos} value={id} selected={to_string(@form[:meta_schema_header_id].value) == to_string(id)}>
                      {label}
                    </option>
                  </select>
                </div>

                <div>
                  <label class="block text-xs text-gray-500 mb-1">Credencial</label>
                  <select name={@form[:credencial_id].name}
                    class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm" required>
                    <option value="">— elegir —</option>
                    <option :for={credencial <- @credenciales} value={credencial.id} selected={to_string(@form[:credencial_id].value) == to_string(credencial.id)}>
                      {credencial.nombre}
                    </option>
                  </select>
                  <p :if={@form[:credencial_id].errors != []} class="text-[11px] text-red-600 mt-0.5">{elem(hd(@form[:credencial_id].errors), 0)}</p>
                </div>
              </div>

              <div class="grid grid-cols-[120px_1fr] gap-3">
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Método</label>
                  <select name={@form[:metodo].name} class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm">
                    <option :for={m <- AccionExterna.metodos()} value={m} selected={@form[:metodo].value == m}>{m}</option>
                  </select>
                </div>

                <div>
                  <label class="block text-xs text-gray-500 mb-1">
                    URL template
                    <span class="text-gray-400 font-normal">— {"{campo}"}, {"{api_key}"}, {"{base_url}"}</span>
                  </label>
                  <input type="text" name={@form[:url_template].name} value={@form[:url_template].value}
                    placeholder="{base_url}/clientes/{meta_fixture_cliente_id}/validar"
                    class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono" required />
                  <p :if={@form[:url_template].errors != []} class="text-[11px] text-red-600 mt-0.5">{elem(hd(@form[:url_template].errors), 0)}</p>
                </div>
              </div>

              <div>
                <label class="block text-xs text-gray-500 mb-1">Headers (JSON)</label>
                <textarea
                  name="headers_template_texto"
                  rows="3"
                  placeholder={"{\"Authorization\": \"Bearer {api_key}\"}"}
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono"
                >{@headers_template_texto}</textarea>
                <p :if={@form[:headers_template].errors != []} class="text-[11px] text-red-600 mt-0.5">{elem(hd(@form[:headers_template].errors), 0)}</p>
              </div>

              <div>
                <label class="block text-xs text-gray-500 mb-1">Body (opcional)</label>
                <textarea name={@form[:body_template].name} rows="3"
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 text-sm font-mono"
                >{@form[:body_template].value}</textarea>
              </div>

              <label class="flex items-center gap-2 text-xs text-gray-600">
                <input type="hidden" name={@form[:confirmar_antes].name} value="false" />
                <input type="checkbox" name={@form[:confirmar_antes].name} value="true" checked={@form[:confirmar_antes].value == true}
                  class="rounded border-gray-300" />
                Pedir confirmación antes de ejecutar (acciones que escriben en el sistema externo)
              </label>

              <div class="flex justify-between items-center pt-2 border-t border-gray-100">
                <button
                  :if={is_struct(@accion_seleccionada)}
                  type="button"
                  phx-click="eliminar_accion"
                  data-confirm={"¿Eliminar la acción \"#{@accion_seleccionada.nombre}\"?"}
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

            <.panel_log :if={is_struct(@accion_seleccionada)} log={@log} />
          <% else %>
            <p class="text-sm text-gray-400">Seleccioná una acción de la izquierda, o creá una nueva.</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Fase 8 ("Integraciones") -- "¿esto de verdad corrió cuando alguien lo
  # clickeó?" sin salir de la pantalla de config. Solo lectura, últimas 20
  # (ver Integraciones.listar_log/2) -- no hay paginación acá a propósito,
  # es un panel de diagnóstico rápido, no un reporte.
  attr :log, :list, required: true

  defp panel_log(assigns) do
    ~H"""
    <div class="mt-5 pt-4 border-t border-gray-100 max-w-lg">
      <h3 class="text-xs font-bold text-gray-700 mb-2">Últimas ejecuciones</h3>

      <p :if={@log == []} class="text-xs text-gray-400">Todavía no se ejecutó ninguna vez.</p>

      <div :if={@log != []} class="space-y-1">
        <div :for={fila <- @log} class="flex items-center justify-between gap-2 text-[11px] px-2 py-1 rounded-lg bg-gray-50">
          <div class="flex items-center gap-2 min-w-0">
            <span class={["w-1.5 h-1.5 rounded-full shrink-0", fila.ok && "bg-green-500", !fila.ok && "bg-red-500"]}></span>
            <span class="text-gray-500 shrink-0">{Calendar.strftime(fila.inserted_at, "%Y-%m-%d %H:%M:%S")}</span>
            <span class="text-gray-400 shrink-0">{fila.origen}</span>
            <span :if={fila.usuario} class="text-gray-400 truncate">{fila.usuario.email}</span>
            <span :if={fila.error} class="text-red-600 truncate" title={fila.error}>{fila.error}</span>
          </div>
          <span class="text-gray-400 font-mono shrink-0">
            {if fila.status_http, do: "HTTP #{fila.status_http}"}{if fila.duracion_ms, do: " · #{fila.duracion_ms}ms"}
          </span>
        </div>
      </div>
    </div>
    """
  end
end
