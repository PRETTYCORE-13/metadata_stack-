defmodule MetadataAppWeb.Sysadmin.BcListLive do
  use MetadataAppWeb, :live_view_admin

  alias MetadataApp.MetaSchemaContext
  alias MetadataAppWeb.AdminNav

  @topic "bc_contextos"
  @por_pagina 50

  # Menú hardcodeado del perfil sysadmin — todavía no hay login, así que
  # esta pantalla es de acceso directo. Según se agreguen secciones, se
  # suman aquí (por ahora solo "BC List").
  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"}
  ]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(MetadataApp.PubSub, @topic)

    {:ok,
     socket
     |> assign(:current_page, "bc_list")
     |> assign(:menu_items, @menu)
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)
     |> assign(:show_prettycore_children, false)
     |> assign(:busqueda, "")
     |> assign(:pagina, 1)
     |> assign(:carpetas_colapsadas, MapSet.new())
     |> cargar_headers()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "bc_list")
  end

  # Cada búsqueda nueva arranca desde la página 1 — si no, podrías quedar
  # parado en una página que ya ni existe con los resultados filtrados.
  def handle_event("buscar", %{"value" => valor}, socket) do
    {:noreply, socket |> assign(:busqueda, valor) |> assign(:pagina, 1) |> cargar_headers()}
  end

  def handle_event("pagina_anterior", _params, socket) do
    {:noreply, socket |> assign(:pagina, max(socket.assigns.pagina - 1, 1)) |> cargar_headers()}
  end

  def handle_event("pagina_siguiente", _params, socket) do
    {:noreply, socket |> assign(:pagina, socket.assigns.pagina + 1) |> cargar_headers()}
  end

  # Colapsar/expandir un grupo de la tabla — estado solo de esta pantalla
  # (no se guarda en el servidor entre sesiones, se resetea al recargar).
  def handle_event("toggle_carpeta", %{"ruta" => ruta}, socket) do
    colapsadas = socket.assigns.carpetas_colapsadas

    colapsadas =
      if MapSet.member?(colapsadas, ruta) do
        MapSet.delete(colapsadas, ruta)
      else
        MapSet.put(colapsadas, ruta)
      end

    {:noreply, assign(socket, :carpetas_colapsadas, colapsadas)}
  end

  # El formulario de creación (BcNuevoLive) avisa por PubSub al terminar de
  # guardar, así esta lista se refresca sola sin que el usuario recargue.
  def handle_info({:bc_creado, _header}, socket) do
    {:noreply, cargar_headers(socket)}
  end

  # Se pagina la lista PLANA (antes de armar el árbol) — por eso una carpeta
  # puede aparecer "incompleta" en una página y seguir en la siguiente, es el
  # trade-off normal de paginar algo que se agrupa después. Con @por_pagina
  # bastante alto (50) esto casi no se nota en la práctica.
  defp cargar_headers(socket) do
    filtrados =
      MetaSchemaContext.listar_headers()
      |> Enum.map(&MetaSchemaContext.item_de_header/1)
      |> Enum.filter(&coincide_busqueda?(&1, socket.assigns.busqueda))

    total_items = length(filtrados)
    total_paginas = max(ceil(total_items / @por_pagina), 1)
    pagina = socket.assigns.pagina |> max(1) |> min(total_paginas)

    arbol =
      filtrados
      |> Enum.slice((pagina - 1) * @por_pagina, @por_pagina)
      |> MetaSchemaContext.construir_arbol()

    socket
    |> assign(:arbol, arbol)
    |> assign(:pagina, pagina)
    |> assign(:total_paginas, total_paginas)
    |> assign(:total_items, total_items)
  end

  defp coincide_busqueda?(_item, ""), do: true

  defp coincide_busqueda?(item, busqueda) do
    objetivo = normalizar_busqueda(item.label) <> " " <> normalizar_busqueda(item.id)
    String.contains?(objetivo, normalizar_busqueda(busqueda))
  end

  defp normalizar_busqueda(texto) do
    texto
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-8">
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">BC List</h1>
        <button
          type="button"
          id="btn-nuevo-contexto"
          phx-hook="AbrirVentana"
          data-url="/sysadmin/bc-list/nuevo"
          class="bg-purple-600 hover:bg-purple-700 text-white font-bold px-6 py-2 rounded"
        >
          + Nuevo
        </button>
      </div>

      <div class="mb-4">
        <input
          type="text"
          value={@busqueda}
          phx-keyup="buscar"
          phx-debounce="200"
          placeholder="Buscar por nombre o etiqueta..."
          class="w-full border border-gray-300 rounded-lg px-4 py-2 text-sm text-gray-900"
        />
      </div>

      <div class="overflow-x-auto rounded-xl border border-gray-200">
        <table class="min-w-full divide-y divide-gray-200 text-sm">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Nombre de sistema</th>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Etiqueta</th>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Navegación</th>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Es visible</th>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Acciones</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <.filas_arbol nodos={@arbol} carpetas_colapsadas={@carpetas_colapsadas} />
            <%= if @arbol == [] do %>
              <tr>
                <td class="px-4 py-6 text-center text-gray-400" colspan="5">
                  {if @busqueda == "", do: "Todavía no hay contextos creados", else: "Sin resultados para \"#{@busqueda}\""}
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%= if @total_paginas > 1 do %>
        <div class="flex items-center justify-between mt-4 text-sm text-gray-600">
          <span>
            Página {@pagina} de {@total_paginas} ({@total_items} en total)
          </span>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="pagina_anterior"
              disabled={@pagina <= 1}
              class="px-3 py-1.5 rounded border border-gray-300 disabled:opacity-40 disabled:cursor-not-allowed hover:bg-gray-50"
            >
              ← Anterior
            </button>
            <button
              type="button"
              phx-click="pagina_siguiente"
              disabled={@pagina >= @total_paginas}
              class="px-3 py-1.5 rounded border border-gray-300 disabled:opacity-40 disabled:cursor-not-allowed hover:bg-gray-50"
            >
              Siguiente →
            </button>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Filas de la tabla agrupadas igual que el menú: una fila de encabezado
  # gris por carpeta, recursivo para soportar carpetas anidadas.
  attr :nodos, :list, required: true
  attr :nivel, :integer, default: 0

  attr :carpetas_colapsadas, :any, default: MapSet.new()
  attr :ruta_padre, :string, default: ""

  def filas_arbol(assigns) do
    ~H"""
    <%= for nodo <- @nodos do %>
      <%= if nodo.tipo == :carpeta do %>
        <% ruta = if @ruta_padre == "", do: nodo.segmento, else: @ruta_padre <> "/" <> nodo.segmento %>
        <% colapsada? = MapSet.member?(@carpetas_colapsadas, ruta) %>
        <tr
          class="bg-gray-50 cursor-pointer hover:bg-gray-100"
          phx-click="toggle_carpeta"
          phx-value-ruta={ruta}
        >
          <td
            colspan="5"
            class="px-4 py-1.5 font-semibold text-gray-500 text-xs uppercase tracking-wide select-none"
            style={"padding-left: #{16 + @nivel * 20}px"}
          >
            <span class="inline-block w-3">{if colapsada?, do: "▸", else: "▾"}</span>
            📁 {nodo.nombre}
          </td>
        </tr>
        <%= if !colapsada? do %>
          <.filas_arbol nodos={nodo.hijos} nivel={@nivel + 1} carpetas_colapsadas={@carpetas_colapsadas} ruta_padre={ruta} />
        <% end %>
      <% else %>
        <tr>
          <td class="px-4 py-2 text-gray-800" style={"padding-left: #{16 + @nivel * 20}px"}>{nodo.id}</td>
          <td class="px-4 py-2 text-gray-800">{nodo.label}</td>
          <td class="px-4 py-2 text-gray-800">{nodo.nav}</td>
          <td class="px-4 py-2 text-gray-800">{if nodo.visible, do: "Sí", else: "No"}</td>
          <td class="px-4 py-2">
            <div class="flex gap-2">
              <button type="button" class="text-blue-600 hover:text-blue-800 text-xs font-semibold">
                Editar
              </button>
              <button type="button" class="text-red-600 hover:text-red-800 text-xs font-semibold">
                Eliminar
              </button>
            </div>
          </td>
        </tr>
      <% end %>
    <% end %>
    """
  end
end
