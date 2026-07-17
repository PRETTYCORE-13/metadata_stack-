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
         |> assign(:filtros, %{})
         |> assign(:busqueda_general, "")
         |> cargar_filas()}
    end
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, socket.assigns.current_page)
  end

  # Búsqueda general: mismo texto contra CUALQUIER columna (OR), a
  # diferencia de los filtros de arriba (AND por columna, para acotar).
  # Conviven las dos — ver aplicar_busqueda/2 en CatalogoGenerico.
  def handle_event("buscar_general", %{"value" => valor}, socket) do
    {:noreply, socket |> assign(:busqueda_general, valor) |> assign(:pagina, 1) |> cargar_filas()}
  end

  def handle_event("pagina_anterior", _params, socket) do
    {:noreply, socket |> assign(:pagina, max(socket.assigns.pagina - 1, 1)) |> cargar_filas()}
  end

  def handle_event("pagina_siguiente", _params, socket) do
    {:noreply, socket |> assign(:pagina, socket.assigns.pagina + 1) |> cargar_filas()}
  end

  # Cualquier cambio en la barra de filtros vuelve a la página 1 — si no,
  # podrías quedar parado en una página que ya ni existe con el resultado
  # filtrado.
  def handle_event("filtrar", %{"filtros" => filtros}, socket) do
    {:noreply, socket |> assign(:filtros, filtros) |> assign(:pagina, 1) |> cargar_filas()}
  end

  def handle_event("limpiar_filtros", _params, socket) do
    {:noreply, socket |> assign(:filtros, %{}) |> assign(:pagina, 1) |> cargar_filas()}
  end

  # Paginación real por SQL (limit/offset en la query, no traer todo y
  # cortar en el LiveView) — a diferencia de BcListLive, que pagina en
  # memoria porque ahí son decenas de Business Contexts, no potencialmente
  # miles de filas de datos de un catálogo real.
  defp cargar_filas(socket) do
    %{
      modulo: modulo,
      estados_por_id: estados_por_id,
      columnas: columnas,
      filtros: filtros,
      busqueda_general: busqueda_general
    } = socket.assigns

    if modulo do
      filtros_ecto = construir_filtros_ecto(filtros, columnas)
      campos_busqueda = Enum.map(columnas, & &1.schema_context_field)
      busqueda = {busqueda_general, campos_busqueda}

      total_filas = CatalogoGenerico.contar(modulo, filtros_ecto, busqueda)
      total_paginas = max(ceil(total_filas / @por_pagina), 1)
      pagina = socket.assigns.pagina |> max(1) |> min(total_paginas)
      offset = (pagina - 1) * @por_pagina

      filas =
        modulo
        |> CatalogoGenerico.listar(filtros_ecto, [limit: @por_pagina, offset: offset], busqueda)
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

  # A partir de los valores crudos de la barra de filtros (todo strings,
  # como llega cualquier form) arma el mapa de filtros que entiende
  # CatalogoGenerico.listar/contar — el tipo de cada columna (guardado en
  # meta_schema_detail) decide qué operador usar, así un catálogo nuevo
  # sale con filtros funcionando solo, sin escribir nada a mano por
  # catálogo: string -> contiene, boolean -> igualdad, integer/decimal/date
  # -> rango desde/hasta, cualquier otro tipo (enum, referencia) -> texto
  # exacto como fallback razonable.
  defp construir_filtros_ecto(filtros, columnas) do
    Enum.reduce(columnas, %{}, fn columna, acc ->
      campo = columna.schema_context_field
      tipo = columna.schema_context_properties["tipo"]
      agregar_filtro_ecto(acc, campo, tipo, filtros)
    end)
  end

  defp agregar_filtro_ecto(acc, campo, "boolean", filtros) do
    case Map.get(filtros, campo) do
      "true" -> Map.put(acc, campo, true)
      "false" -> Map.put(acc, campo, false)
      _ -> acc
    end
  end

  defp agregar_filtro_ecto(acc, campo, tipo, filtros) when tipo in ["integer", "decimal", "date"] do
    desde = Map.get(filtros, "#{campo}_desde") |> valor_no_vacio() |> convertir(tipo)
    hasta = Map.get(filtros, "#{campo}_hasta") |> valor_no_vacio() |> convertir(tipo)

    if desde || hasta, do: Map.put(acc, campo, {:entre, {desde, hasta}}), else: acc
  end

  defp agregar_filtro_ecto(acc, campo, _tipo, filtros) do
    case Map.get(filtros, campo) |> valor_no_vacio() do
      nil -> acc
      texto -> Map.put(acc, campo, {:ilike, texto})
    end
  end

  defp valor_no_vacio(nil), do: nil
  defp valor_no_vacio(""), do: nil
  defp valor_no_vacio(v), do: v

  defp convertir(nil, _tipo), do: nil
  defp convertir(v, "integer"), do: parsear(fn -> String.to_integer(v) end)
  defp convertir(v, "decimal"), do: parsear(fn -> Decimal.new(v) end)
  defp convertir(v, "date"), do: parsear(fn -> Date.from_iso8601!(v) end)

  # Si el usuario deja algo no parseable a medio escribir (ej. "10." en un
  # decimal), se ignora ese lado del rango en vez de tronar la pantalla.
  defp parsear(fun) do
    fun.()
  rescue
    _ -> nil
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

      <div class="mb-3">
        <input
          type="text"
          value={@busqueda_general}
          phx-keyup="buscar_general"
          phx-debounce="300"
          placeholder="Buscar en cualquier columna..."
          class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-900"
        />
      </div>

      <form phx-change="filtrar" class="flex flex-wrap items-end gap-3 mb-3 p-3 rounded-xl border border-gray-200 bg-gray-50">
        <%= for columna <- @columnas do %>
          <.filtro_columna columna={columna} valores={@filtros} />
        <% end %>
        <button
          type="button"
          phx-click="limpiar_filtros"
          class="text-xs font-semibold text-gray-500 hover:text-gray-800 px-2 py-1.5"
        >
          Limpiar filtros
        </button>
      </form>

      <div class="overflow-x-auto rounded-xl border border-gray-200">
        <table class="min-w-full divide-y divide-gray-200 text-xs">
          <thead class="bg-gray-50">
            <tr>
              <%= for columna <- @columnas do %>
                <th class="px-3 py-2 text-left text-sm font-semibold text-gray-600">
                  {columna.schema_context_properties["etiqueta"]}
                </th>
              <% end %>
              <%= if @mostrar_estado? do %>
                <th class="px-3 py-2 text-left text-sm font-semibold text-gray-600">Estado</th>
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

  # Un widget de filtro distinto según el tipo de la columna (guardado en
  # meta_schema_detail) — así un catálogo nuevo sale con filtros
  # funcionando sin escribir nada a mano por catálogo. Los nombres de los
  # inputs (filtros[campo] / filtros[campo_desde] / filtros[campo_hasta])
  # tienen que calzar con lo que lee construir_filtros_ecto/2.
  attr :columna, :map, required: true
  attr :valores, :map, required: true

  defp filtro_columna(%{columna: %{schema_context_properties: %{"tipo" => "boolean"}}} = assigns) do
    campo = assigns.columna.schema_context_field
    assigns = assign(assigns, :campo, campo)

    ~H"""
    <div class="flex flex-col gap-1">
      <label class="text-[11px] font-semibold text-gray-500">{@columna.schema_context_properties["etiqueta"]}</label>
      <select name={"filtros[#{@campo}]"} class="border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5">
        <option value="" selected={@valores[@campo] in [nil, ""]}>Todos</option>
        <option value="true" selected={@valores[@campo] == "true"}>Sí</option>
        <option value="false" selected={@valores[@campo] == "false"}>No</option>
      </select>
    </div>
    """
  end

  defp filtro_columna(%{columna: %{schema_context_properties: %{"tipo" => tipo}}} = assigns)
       when tipo in ["integer", "decimal", "date"] do
    campo = assigns.columna.schema_context_field
    tipo_input = if tipo == "date", do: "date", else: "number"
    assigns = assigns |> assign(:campo, campo) |> assign(:tipo_input, tipo_input)

    ~H"""
    <div class="flex flex-col gap-1">
      <label class="text-[11px] font-semibold text-gray-500">{@columna.schema_context_properties["etiqueta"]}</label>
      <div class="flex items-center gap-1">
        <input
          type={@tipo_input}
          name={"filtros[#{@campo}_desde]"}
          value={@valores["#{@campo}_desde"]}
          placeholder="Desde"
          phx-debounce="400"
          class="border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5 w-24"
        />
        <span class="text-gray-400 text-xs">–</span>
        <input
          type={@tipo_input}
          name={"filtros[#{@campo}_hasta]"}
          value={@valores["#{@campo}_hasta"]}
          placeholder="Hasta"
          phx-debounce="400"
          class="border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5 w-24"
        />
      </div>
    </div>
    """
  end

  defp filtro_columna(assigns) do
    campo = assigns.columna.schema_context_field
    assigns = assign(assigns, :campo, campo)

    ~H"""
    <div class="flex flex-col gap-1">
      <label class="text-[11px] font-semibold text-gray-500">{@columna.schema_context_properties["etiqueta"]}</label>
      <input
        type="text"
        name={"filtros[#{@campo}]"}
        value={@valores[@campo]}
        placeholder="Buscar..."
        phx-debounce="400"
        class="border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5 w-32"
      />
    </div>
    """
  end
end
