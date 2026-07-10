defmodule MetadataAppWeb.CatalogoLive do
  use MetadataAppWeb, :live_view_admin

  alias MetadataApp.MetaSchemaContext
  alias MetadataApp.CatalogoGenerico
  alias MetadataApp.StateEngine
  alias MetadataAppWeb.AdminNav

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

        estados_por_id = StateEngine.mapa_nombres_estados(header.schema_context_name)

        filas =
          if modulo do
            modulo
            |> CatalogoGenerico.listar()
            |> Enum.map(&CatalogoGenerico.serializar(&1, estados_por_id))
          else
            []
          end

        {:ok,
         socket
         |> assign(:current_page, header.schema_context_name)
         |> assign(:encontrado?, true)
         |> assign(:label, header.schema_context_label)
         |> assign(:columnas, columnas)
         |> assign(:mostrar_estado?, estados_por_id != %{})
         |> assign(:filas, filas)}
    end
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, socket.assigns.current_page)
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
    <div class="p-8">
      <h1 class="text-2xl font-bold mb-4">{@label}</h1>

      <div class="overflow-x-auto rounded-xl border border-gray-200">
        <table class="min-w-full divide-y divide-gray-200 text-sm">
          <thead class="bg-gray-50">
            <tr>
              <%= for columna <- @columnas do %>
                <th class="px-4 py-2 text-left font-semibold text-gray-600">
                  {columna.schema_context_properties["etiqueta"]}
                </th>
              <% end %>
              <%= if @mostrar_estado? do %>
                <th class="px-4 py-2 text-left font-semibold text-gray-600">Estado</th>
              <% end %>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <%= for fila <- @filas do %>
              <tr>
                <%= for columna <- @columnas do %>
                  <td class="px-4 py-2 text-gray-800">
                    {Map.get(fila, String.to_existing_atom(columna.schema_context_field))}
                  </td>
                <% end %>
                <%= if @mostrar_estado? do %>
                  <td class="px-4 py-2 text-gray-800">{Map.get(fila, :estado_nombre)}</td>
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
