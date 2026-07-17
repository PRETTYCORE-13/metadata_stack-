defmodule MetadataAppWeb.Sysadmin.BcEditarCarpetaLive do
  # Ventana emergente, igual que BcNuevoLive — solo el formulario, sin
  # sidebar/topbar. Deliberadamente separado de BcNuevoLive en vez de
  # meterle un "modo edición": una carpeta no tiene tabla ni Componentes,
  # así que el formulario de edición es mucho más chico (etiqueta, ícono,
  # visible) y mezclarlo con el de creación (que sí maneja archivo/carpeta,
  # 3 cajitas de nombre, Componentes, etc.) le habría sumado condicionales
  # a algo que ya es largo.
  use MetadataAppWeb, :live_view

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias Phoenix.LiveView.JS

  @topic "bc_contextos"

  # Mismo set curado que BcNuevoLive — si se desincroniza no es grave (el
  # campo de texto libre sigue aceptando cualquier ícono), pero lo ideal es
  # mantenerlos iguales.
  @iconos_sugeridos ~w(
    inventory_2 inventory shopping_cart storefront store sell local_offer
    category label folder folder_open description receipt_long assignment
    checklist rule task list_alt table_chart grid_view apps widgets
    dashboard bar_chart pie_chart insights trending_up payments credit_card
    attach_money account_balance business apartment factory warehouse
    local_shipping directions_car build engineering handyman construction
    group person people badge admin_panel_settings support_agent
    notifications campaign mail chat event schedule calendar_month
    place map public language security lock key qr_code print
    archive star favorite flag settings tune
  )

  def mount(%{"nombre" => nombre}, _session, socket) do
    header = MetaSchemaContext.obtener_header_por_nombre(nombre)

    {:ok,
     socket
     |> assign(:mensaje, nil)
     |> assign(:header, header)
     |> assign(:iconos_sugeridos, @iconos_sugeridos)
     |> assign(:contexto, contexto_desde_header(header))}
  end

  defp contexto_desde_header(nil), do: %{}

  defp contexto_desde_header(header) do
    %{
      "etiqueta" => header.schema_context_label,
      "icono" => header.schema_context_icono || "",
      "visible" => header.schema_visible
    }
  end

  def handle_event("validar", %{"contexto" => contexto}, socket) do
    contexto =
      contexto
      |> Map.put("icono", normalizar_icono(contexto["icono"]))
      |> Map.put("visible", contexto["visible"] == "true")

    {:noreply, assign(socket, :contexto, contexto)}
  end

  def handle_event("elegir_icono", %{"icono" => icono}, socket) do
    {:noreply, update(socket, :contexto, &Map.put(&1, "icono", icono))}
  end

  def handle_event("cancelar", _params, socket) do
    {:noreply, push_event(socket, "cerrar_ventana", %{})}
  end

  def handle_event("guardar", %{"contexto" => contexto}, socket) do
    case validar_etiqueta(contexto["etiqueta"]) do
      :ok ->
        attrs = %{
          "schema_context_label" => String.trim(contexto["etiqueta"]),
          "schema_context_icono" => nil_si_vacio(normalizar_icono(contexto["icono"])),
          "schema_visible" => contexto["visible"] == "true"
        }

        case MetaSchemaContext.actualizar_header(socket.assigns.header, attrs) do
          {:ok, header} ->
            Phoenix.PubSub.broadcast(MetadataApp.PubSub, @topic, {:bc_actualizado, header})

            {:noreply,
             socket
             |> assign(:mensaje, {:ok, "Carpeta '#{header.schema_context_label}' actualizada."})
             |> push_event("cerrar_ventana", %{})}

          {:error, changeset} ->
            {:noreply, assign(socket, :mensaje, {:error, resumen_errores(changeset)})}
        end

      {:error, motivo} ->
        {:noreply, assign(socket, :mensaje, {:error, motivo})}
    end
  end

  defp validar_etiqueta(valor) do
    if valor && String.trim(valor) != "" do
      :ok
    else
      {:error, "La etiqueta no puede quedar vacía."}
    end
  end

  defp normalizar_icono(valor) do
    (valor || "")
    |> String.trim()
    |> String.downcase()
    |> quitar_acentos()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 50)
  end

  defp quitar_acentos(valor) do
    valor
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  defp nil_si_vacio(""), do: nil
  defp nil_si_vacio(valor), do: valor

  defp resumen_errores(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> inspect()
  end

  def render(%{header: nil} = assigns) do
    ~H"""
    <div class="min-h-screen bg-white flex items-center justify-center">
      <p class="text-gray-600">Esa carpeta ya no existe (puede que alguien más la haya borrado).</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-white">
    <div class="max-w-2xl mx-auto">
      <div class="bg-black text-white px-6 py-3 flex justify-end">
        <span class="italic">Business Contexts Admin — Editar carpeta</span>
      </div>

      <%= if @mensaje do %>
        <div class={[
          "px-6 py-3 text-sm font-medium",
          elem(@mensaje, 0) == :ok && "bg-green-50 text-green-700",
          elem(@mensaje, 0) == :error && "bg-red-50 text-red-700"
        ]}>
          {elem(@mensaje, 1)}
        </div>
      <% end %>

      <form phx-submit="guardar" phx-change="validar" class="p-6 space-y-6">
        <fieldset class="border border-blue-300 rounded">
          <legend class="px-2 ml-2 text-sm font-semibold text-gray-900">Contexto</legend>
          <div class="grid grid-cols-[160px_1fr] gap-y-3 gap-x-3 p-4 items-center">
            <label class="font-medium text-gray-900">Nombre de sistema:</label>
            <span class="font-mono text-sm text-gray-500">{@header.schema_context_name}</span>

            <label class="font-medium text-gray-900">Navegación:</label>
            <div>
              <span class="font-mono text-sm text-gray-500">{@header.schema_context_nav}</span>
              <p class="mt-1 text-xs text-gray-500">
                La ruta no se edita aquí — cambiarla desconectaría los catálogos que ya
                están anidados adentro. Si de verdad hace falta moverla, bórrala y créala
                de nuevo en la ruta correcta.
              </p>
            </div>

            <label class="font-medium text-gray-900">Etiqueta:</label>
            <input type="text" name="contexto[etiqueta]" value={@contexto["etiqueta"]} required maxlength="100"
              class="border border-gray-300 rounded text-gray-900 px-2 py-1" placeholder="Catálogo de carros" />

            <label class="font-medium text-gray-900">Ícono:</label>
            <div>
              <input type="hidden" name="contexto[icono]" value={@contexto["icono"]} />
              <button
                type="button"
                phx-click={JS.toggle(to: "#selector-iconos-editar")}
                class="w-9 h-9 flex items-center justify-center border border-gray-300 rounded bg-gray-50 hover:bg-gray-100 text-gray-700"
                title="Elegir ícono"
              >
                <%= if @contexto["icono"] not in [nil, ""] do %>
                  <span class="material-symbols-outlined">{@contexto["icono"]}</span>
                <% else %>
                  <span class="material-symbols-outlined text-gray-400">apps</span>
                <% end %>
              </button>

              <div id="selector-iconos-editar" class="hidden mt-1.5 border border-gray-200 rounded-lg bg-white shadow-sm p-2 max-w-md">
                <div class="grid grid-cols-8 gap-1 max-h-48 overflow-y-auto">
                  <%= for icono <- @iconos_sugeridos do %>
                    <button
                      type="button"
                      title={icono}
                      phx-click={JS.push("elegir_icono", value: %{icono: icono}) |> JS.hide(to: "#selector-iconos-editar")}
                      class={[
                        "w-9 h-9 flex items-center justify-center rounded text-gray-700 hover:bg-purple-50 hover:text-purple-700",
                        @contexto["icono"] == icono && "bg-purple-100 text-purple-700"
                      ]}
                    >
                      <span class="material-symbols-outlined">{icono}</span>
                    </button>
                  <% end %>
                </div>
              </div>

              <p class="mt-1 text-xs text-gray-500">Opcional — se ve en el menú colapsado.</p>
            </div>

            <label class="font-medium text-gray-900">Es visible:</label>
            <div>
              <input type="hidden" name="contexto[visible]" value="false" />
              <input type="checkbox" name="contexto[visible]" value="true" checked={@contexto["visible"] == true} />
            </div>
          </div>
        </fieldset>

        <div class="flex justify-end gap-3">
          <button type="button" phx-click="cancelar" class="bg-red-500 hover:bg-red-600 text-white font-bold px-8 py-2 rounded">
            Cancelar
          </button>
          <button type="submit" class="bg-green-500 hover:bg-green-600 text-white font-bold px-8 py-2 rounded">
            Guardar
          </button>
        </div>
      </form>
    </div>
    </div>
    """
  end
end
