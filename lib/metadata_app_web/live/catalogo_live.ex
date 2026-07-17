defmodule MetadataAppWeb.CatalogoLive do
  use MetadataAppWeb, :live_view_admin

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.MetaStateEngine
  alias MetadataAppWeb.AdminNav

  @por_pagina 25

  def mount(%{"ruta" => segmentos}, _session, socket) do
    nav = "/" <> Enum.join(segmentos, "/")

    socket =
      socket
      |> assign(:sidebar_open, false)
      |> assign(:show_programacion_children, false)
      |> assign(:show_clientes_children, false)
      |> assign(:show_prettycore_children, false)

    case MetaSchemaContext.obtener_header_por_nav(nav) do
      nil ->
        {:ok,
         socket
         |> assign(:current_page, nav)
         |> assign(:encontrado?, false)}

      header ->
        modulo = MetaSchemaContext.modulo_por_nombre(header.schema_context_name)

        columnas =
          header.schema_context_name
          |> MetaSchemaContext.listar_detalles()
          |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
          |> Enum.filter(&get_in(&1, [:schema_context_properties, "visible"]))
          |> Enum.sort_by(&get_in(&1, [:schema_context_properties, "orden"]))

        estados_por_id = MetaStateEngine.mapa_nombres_estados(header.schema_context_name)

        {:ok,
         socket
         |> assign(:current_page, header.schema_context_name)
         |> assign(:encontrado?, true)
         |> assign(:label, header.schema_context_label)
         |> assign(:columnas, columnas)
         |> assign(:mostrar_estado?, estados_por_id != %{})
         |> assign(:modulo, modulo)
         |> assign(:estados_por_id, estados_por_id)
         |> assign(:pagina, 1)
         |> cargar_filas()}
    end
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, socket.assigns.current_page)
  end

  def handle_event("pagina_anterior", _params, socket) do
    {:noreply, socket |> assign(:pagina, max(socket.assigns.pagina - 1, 1)) |> cargar_filas()}
  end

  def handle_event("pagina_siguiente", _params, socket) do
    {:noreply, socket |> assign(:pagina, socket.assigns.pagina + 1) |> cargar_filas()}
  end

  # Paginación real por SQL (limit/offset en la query, no traer todo y
  # cortar en el LiveView) — a diferencia de BcListLive, que pagina en
  # memoria porque ahí son decenas de Business Contexts, no potencialmente
  # miles de filas de datos de un catálogo real.
  defp cargar_filas(socket) do
    %{modulo: modulo, estados_por_id: estados_por_id} = socket.assigns

    if modulo do
      total_filas = CatalogoGenerico.contar(modulo)
      total_paginas = max(ceil(total_filas / @por_pagina), 1)
      pagina = socket.assigns.pagina |> max(1) |> min(total_paginas)
      offset = (pagina - 1) * @por_pagina

      filas =
        modulo
        |> CatalogoGenerico.listar(%{}, limit: @por_pagina, offset: offset)
        |> Enum.map(&CatalogoGenerico.serializar(&1, estados_por_id))

      socket
      |> assign(:filas, filas)
      |> assign(:pagina, pagina)
      |> assign(:total_paginas, total_paginas)
      |> assign(:total_filas, total_filas)
      |> assign(:inicio, if(total_filas == 0, do: 0, else: offset + 1))
      |> assign(:fin, min(offset + @por_pagina, total_filas))
    else
      socket
      |> assign(:filas, [])
      |> assign(:pagina, 1)
      |> assign(:total_paginas, 1)
      |> assign(:total_filas, 0)
      |> assign(:inicio, 0)
      |> assign(:fin, 0)
    end
  end

  def render(%{encontrado?: false} = assigns) do
    ~H"""
    <div class="p-8">
      <h1 class="text-xl font-bold">Catálogo no encontrado</h1>
      <p class="text-gray-500 mt-2">No hay ningún catálogo registrado con esta ruta.</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="p-4">
      <div class="flex items-center justify-between mb-2">
        <h1 class="text-2xl font-bold">{@label}</h1>

        <div class="flex items-center gap-2 text-sm text-gray-600">
          <span>{@inicio}-{@fin} de {@total_filas}</span>
          <button
            type="button"
            phx-click="pagina_anterior"
            disabled={@pagina <= 1}
            aria-label="Página anterior"
            class="w-7 h-7 flex items-center justify-center rounded-full border border-gray-300 text-gray-600 hover:bg-gray-100 disabled:opacity-40 disabled:cursor-not-allowed disabled:hover:bg-transparent transition-colors"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <polyline points="15 18 9 12 15 6" />
            </svg>
          </button>
          <button
            type="button"
            phx-click="pagina_siguiente"
            disabled={@pagina >= @total_paginas}
            aria-label="Página siguiente"
            class="w-7 h-7 flex items-center justify-center rounded-full border border-gray-300 text-gray-600 hover:bg-gray-100 disabled:opacity-40 disabled:cursor-not-allowed disabled:hover:bg-transparent transition-colors"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <polyline points="9 18 15 12 9 6" />
            </svg>
          </button>
        </div>
      </div>

      <div class="overflow-x-auto rounded-xl border border-gray-200">
        <table class="min-w-full divide-y divide-gray-200 text-xs">
          <thead class="bg-gray-50">
            <tr>
              <%= for columna <- @columnas do %>
                <th class="px-2 py-0 text-left font-semibold text-gray-600">
                  {columna.schema_context_properties["etiqueta"]}
                </th>
              <% end %>
              <%= if @mostrar_estado? do %>
                <th class="px-2 py-0 text-left font-semibold text-gray-600">Estado</th>
              <% end %>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <%= for fila <- @filas do %>
              <tr class="hover:bg-violet-100 transition-colors">
                <%= for columna <- @columnas do %>
                  <td class="px-2 py-0 text-gray-800">
                    {Map.get(fila, String.to_existing_atom(columna.schema_context_field))}
                  </td>
                <% end %>
                <%= if @mostrar_estado? do %>
                  <td class="px-2 py-0 text-gray-800">{Map.get(fila, :estado_nombre)}</td>
                <% end %>
              </tr>
            <% end %>
            <%= if @filas == [] do %>
              <tr>
                <td
                  class="px-4 py-6 text-center text-gray-400"
                  colspan={length(@columnas) + if @mostrar_estado?, do: 1, else: 0}
                >
                  Sin registros todavía
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
