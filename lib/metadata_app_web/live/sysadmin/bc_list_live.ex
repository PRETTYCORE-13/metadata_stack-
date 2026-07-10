defmodule MetadataAppWeb.Sysadmin.BcListLive do
  use MetadataAppWeb, :live_view_admin

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataAppWeb.AdminNav

  @topic "bc_contextos"

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
     |> cargar_headers()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "bc_list")
  end

  # El formulario de creación (BcNuevoLive) avisa por PubSub al terminar de
  # guardar, así esta lista se refresca sola sin que el usuario recargue.
  def handle_info({:bc_creado, _header}, socket) do
    {:noreply, cargar_headers(socket)}
  end

  defp cargar_headers(socket) do
    assign(socket, :arbol, MetaSchemaContext.listar_headers_arbol())
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
            <.filas_arbol nodos={@arbol} />
            <%= if @arbol == [] do %>
              <tr>
                <td class="px-4 py-6 text-center text-gray-400" colspan="5">
                  Todavía no hay contextos creados
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # Filas de la tabla agrupadas igual que el menú: una fila de encabezado
  # gris por carpeta, recursivo para soportar carpetas anidadas.
  attr :nodos, :list, required: true
  attr :nivel, :integer, default: 0

  def filas_arbol(assigns) do
    ~H"""
    <%= for nodo <- @nodos do %>
      <%= if nodo.tipo == :carpeta do %>
        <tr class="bg-gray-50">
          <td
            colspan="5"
            class="px-4 py-1.5 font-semibold text-gray-500 text-xs uppercase tracking-wide"
            style={"padding-left: #{16 + @nivel * 20}px"}
          >
            📁 {nodo.nombre}
          </td>
        </tr>
        <.filas_arbol nodos={nodo.hijos} nivel={@nivel + 1} />
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
