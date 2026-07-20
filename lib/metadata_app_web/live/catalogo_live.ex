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
         |> assign(:filtros_activos, [])
         |> assign(:selector_campo_abierto, false)
         |> assign(:busqueda_campo_filtro, "")
         |> assign(:busqueda_general, "")
         |> assign(:mostrar_filtros, false)
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

  def handle_event("abrir_filtros", _params, socket) do
    {:noreply, assign(socket, :mostrar_filtros, true)}
  end

  def handle_event("cerrar_filtros", _params, socket) do
    {:noreply, socket |> assign(:mostrar_filtros, false) |> assign(:selector_campo_abierto, false)}
  end

  def handle_event("abrir_selector_campo", _params, socket) do
    {:noreply, socket |> assign(:selector_campo_abierto, true) |> assign(:busqueda_campo_filtro, "")}
  end

  def handle_event("cerrar_selector_campo", _params, socket) do
    {:noreply, assign(socket, :selector_campo_abierto, false)}
  end

  def handle_event("buscar_campo_filtro", %{"value" => valor}, socket) do
    {:noreply, assign(socket, :busqueda_campo_filtro, valor)}
  end

  # Agregar un campo al panel no lo filtra todavía (no tiene valor) — solo lo
  # hace visible como fila de filtro. cargar_filas/1 no se llama acá porque
  # @filtros no cambió.
  def handle_event("agregar_filtro_campo", %{"campo" => campo}, socket) do
    activos = Enum.uniq(socket.assigns.filtros_activos ++ [campo])

    {:noreply,
     socket
     |> assign(:filtros_activos, activos)
     |> assign(:selector_campo_abierto, false)}
  end

  # Quitar la fila también borra su(s) valor(es) de @filtros — si no, el
  # filtro seguiría aplicándose "invisible" (el usuario ya no lo ve en el
  # panel pero la query seguiría acotada por él).
  def handle_event("quitar_filtro_campo", %{"campo" => campo}, socket) do
    {:noreply,
     socket
     |> assign(:filtros_activos, List.delete(socket.assigns.filtros_activos, campo))
     |> assign(:filtros, quitar_valores_filtro(socket.assigns.filtros, campo))
     |> assign(:pagina, 1)
     |> cargar_filas()}
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

  # Borra tanto la forma simple (filtros["campo"]) como la de rango
  # (filtros["campo_desde"] / filtros["campo_hasta"]) — un campo removido del
  # panel no sabe de antemano cuál de las dos formas tenía.
  defp quitar_valores_filtro(filtros, campo) do
    Map.drop(filtros, [campo, "#{campo}_desde", "#{campo}_hasta"])
  end

  # Cuenta campos con un valor realmente puesto (no solo agregados al panel
  # pero todavía vacíos) — un rango cuenta una sola vez aunque tenga
  # _desde/_hasta. Usado para el badge del botón "Filtros".
  defp contar_filtros_activos(filtros) do
    filtros
    |> Enum.reject(fn {_campo, valor} -> valor in [nil, ""] end)
    |> Enum.map(fn {campo, _valor} -> String.replace_trailing(campo, "_desde", "") |> String.replace_trailing("_hasta", "") end)
    |> Enum.uniq()
    |> length()
  end

  # Columnas que todavía no están agregadas como fila de filtro, filtradas
  # por el buscador del selector — así elegir un campo entre 30 no es
  # desplazarse por una lista larga.
  defp columnas_disponibles(columnas, activos, busqueda) do
    texto = String.downcase(busqueda)

    columnas
    |> Enum.reject(&(&1.schema_context_field in activos))
    |> Enum.filter(fn columna ->
      texto == "" or
        String.contains?(String.downcase(columna.schema_context_properties["etiqueta"] || ""), texto) or
        String.contains?(String.downcase(columna.schema_context_field), texto)
    end)
  end

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
    <div class="p-6">
      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-5">
        <div class="flex items-center justify-between mb-4">
          <h1 class="text-xl font-bold text-gray-900">{@label}</h1>

          <div class="flex items-center gap-2">
            <span class="text-xs font-medium text-gray-500 bg-gray-100 rounded-full px-3 py-1">
              {@inicio}-{@fin} de {@total_filas}
            </span>
            <div class="flex items-center gap-1 bg-gray-50 border border-gray-200 rounded-lg p-0.5">
              <button
                type="button"
                phx-click="pagina_anterior"
                disabled={@pagina <= 1}
                aria-label="Página anterior"
                class="w-7 h-7 flex items-center justify-center rounded-md text-gray-600 hover:bg-white hover:shadow-sm disabled:opacity-30 disabled:cursor-not-allowed disabled:hover:bg-transparent disabled:hover:shadow-none transition"
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
                class="w-7 h-7 flex items-center justify-center rounded-md text-gray-600 hover:bg-white hover:shadow-sm disabled:opacity-30 disabled:cursor-not-allowed disabled:hover:bg-transparent disabled:hover:shadow-none transition"
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                  <polyline points="9 18 15 12 9 6" />
                </svg>
              </button>
            </div>
          </div>
        </div>

        <div class="flex items-center gap-2 mb-4">
          <div class="relative flex-1">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400">
              <circle cx="11" cy="11" r="8" /><line x1="21" y1="21" x2="16.65" y2="16.65" />
            </svg>
            <input
              type="text"
              value={@busqueda_general}
              phx-keyup="buscar_general"
              phx-debounce="300"
              placeholder="Buscar en cualquier columna..."
              class="w-full border border-gray-300 rounded-lg pl-9 pr-3 py-2 text-sm text-gray-900 focus:outline-none focus:ring-2 focus:ring-purple-500/30 focus:border-purple-500"
            />
          </div>
          <div class="relative">
            <button
              type="button"
              phx-click="abrir_filtros"
              class={[
                "flex items-center gap-1.5 border rounded-lg px-3 py-2 text-sm font-semibold whitespace-nowrap transition-colors",
                if(contar_filtros_activos(@filtros) > 0,
                  do: "border-purple-600 bg-purple-50 text-purple-700",
                  else: "border-gray-300 text-gray-600 hover:bg-gray-50"
                )
              ]}
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3" />
              </svg>
              Filtros
              <%= if contar_filtros_activos(@filtros) > 0 do %>
                <span class="inline-flex items-center justify-center w-4 h-4 rounded-full bg-purple-600 text-white text-[10px] font-bold">
                  {contar_filtros_activos(@filtros)}
                </span>
              <% end %>
            </button>

            <.panel_filtros
              mostrar={@mostrar_filtros}
              columnas={@columnas}
              filtros={@filtros}
              filtros_activos={@filtros_activos}
              selector_campo_abierto={@selector_campo_abierto}
              busqueda_campo_filtro={@busqueda_campo_filtro}
            />
          </div>
        </div>

        <div class="overflow-x-auto rounded-xl border border-gray-200">
          <table class="min-w-full divide-y divide-gray-200 text-sm">
            <thead class="bg-gray-50">
              <tr>
                <%= for columna <- @columnas do %>
                  <th class={[
                    "px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide",
                    alineacion_columna(columna)
                  ]}>
                    {columna.schema_context_properties["etiqueta"]}
                  </th>
                <% end %>
                <%= if @mostrar_estado? do %>
                  <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Estado</th>
                <% end %>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <%= for fila <- @filas do %>
                <tr class="hover:bg-purple-50/60 transition-colors">
                  <%= for columna <- @columnas do %>
                    <td class={["px-4 py-1.5 text-xs text-gray-700", alineacion_columna(columna)]}>
                      {Map.get(fila, String.to_existing_atom(columna.schema_context_field))}
                    </td>
                  <% end %>
                  <%= if @mostrar_estado? do %>
                    <td class="px-4 py-1.5 text-xs text-gray-700">{Map.get(fila, :estado_nombre)}</td>
                  <% end %>
                </tr>
              <% end %>
              <%= if @filas == [] do %>
                <tr>
                  <td
                    class="px-4 py-10 text-center text-gray-400 text-sm"
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
    </div>
    """
  end

  # Columnas numéricas alineadas a la derecha (más fácil comparar montos de
  # un vistazo) — el resto se queda a la izquierda como texto normal.
  defp alineacion_columna(%{schema_context_properties: %{"tipo" => tipo}})
       when tipo in ["integer", "decimal"],
       do: "text-right"

  defp alineacion_columna(_columna), do: "text-left"

  # Popover compacto anclado al botón "Filtros" (en vez del drawer de
  # pantalla completa de antes, que se sentía como una ventana aparte para
  # apenas 2-3 campos). El div fixed transparente de atrás solo sirve para
  # cerrar al hacer clic afuera — el popover en sí es "absolute" respecto al
  # contenedor relative del botón, así que aparece pegado a él. El form
  # sigue mandando "filtrar" con phx-change así que los filtros se aplican
  # en vivo aunque el popover siga abierto.
  attr :mostrar, :boolean, required: true
  attr :columnas, :list, required: true
  attr :filtros, :map, required: true
  attr :filtros_activos, :list, required: true
  attr :selector_campo_abierto, :boolean, required: true
  attr :busqueda_campo_filtro, :string, required: true

  defp panel_filtros(%{mostrar: false} = assigns), do: ~H""

  defp panel_filtros(assigns) do
    assigns =
      assign(
        assigns,
        :columnas_disponibles,
        columnas_disponibles(assigns.columnas, assigns.filtros_activos, assigns.busqueda_campo_filtro)
      )

    ~H"""
    <div class="fixed inset-0 z-40" phx-click="cerrar_filtros"></div>
    <div class="absolute right-0 top-full mt-2 w-80 max-h-[70vh] bg-white rounded-xl shadow-xl border border-gray-200 z-50 flex flex-col">
      <div class="flex items-center justify-between px-4 py-2.5 border-b border-gray-200">
        <h2 class="text-sm font-bold text-gray-900">Filtros</h2>
        <button
          type="button"
          phx-click="cerrar_filtros"
          aria-label="Cerrar filtros"
          class="w-6 h-6 flex items-center justify-center rounded-full text-gray-500 hover:bg-gray-100"
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
            <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
          </svg>
        </button>
      </div>

      <div class="relative border-b border-gray-200">
        <button
          type="button"
          phx-click="abrir_selector_campo"
          class="w-full flex items-center gap-1.5 px-4 py-2.5 text-sm font-semibold text-purple-700 hover:bg-purple-50"
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
            <line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" />
          </svg>
          Agregar filtro
        </button>

        <%= if @selector_campo_abierto do %>
          <div class="fixed inset-0 z-40" phx-click="cerrar_selector_campo"></div>
          <div class="absolute left-0 right-0 top-full bg-white border border-gray-200 rounded-lg shadow-lg z-50 mx-2 mb-2">
            <input
              type="text"
              value={@busqueda_campo_filtro}
              phx-keyup="buscar_campo_filtro"
              phx-debounce="150"
              autofocus
              placeholder="Buscar campo..."
              class="w-full border-b border-gray-200 px-3 py-2 text-xs text-gray-900 focus:outline-none rounded-t-lg"
            />
            <div class="max-h-48 overflow-y-auto py-1">
              <%= for columna <- @columnas_disponibles do %>
                <button
                  type="button"
                  phx-click="agregar_filtro_campo"
                  phx-value-campo={columna.schema_context_field}
                  class="w-full text-left px-3 py-1.5 text-xs text-gray-700 hover:bg-purple-50 hover:text-purple-700"
                >
                  {columna.schema_context_properties["etiqueta"]}
                </button>
              <% end %>
              <%= if @columnas_disponibles == [] do %>
                <p class="px-3 py-2 text-xs text-gray-400">
                  {if @columnas == [], do: "No hay campos.", else: "Todos los campos ya están agregados."}
                </p>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <form phx-change="filtrar" class="overflow-y-auto px-4 py-3 flex flex-col gap-3">
        <%= if @filtros_activos == [] do %>
          <p class="text-xs text-gray-400 text-center py-4">
            Sin filtros agregados — usa "Agregar filtro" para elegir un campo.
          </p>
        <% end %>
        <%= for campo <- @filtros_activos, columna = Enum.find(@columnas, &(&1.schema_context_field == campo)), columna do %>
          <div class="flex items-start gap-1">
            <div class="flex-1">
              <.filtro_columna columna={columna} valores={@filtros} />
            </div>
            <button
              type="button"
              phx-click="quitar_filtro_campo"
              phx-value-campo={campo}
              aria-label={"Quitar filtro de #{columna.schema_context_properties["etiqueta"]}"}
              class="mt-5 w-5 h-5 flex-shrink-0 flex items-center justify-center rounded-full text-gray-400 hover:bg-gray-100 hover:text-gray-700"
            >
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
              </svg>
            </button>
          </div>
        <% end %>
      </form>

      <div class="px-4 py-2.5 border-t border-gray-200 flex justify-between items-center">
        <button
          type="button"
          phx-click="limpiar_filtros"
          class="text-xs font-semibold text-gray-500 hover:text-gray-800 px-2 py-1"
        >
          Limpiar filtros
        </button>
        <button
          type="button"
          phx-click="cerrar_filtros"
          class="px-3 py-1.5 rounded bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700"
        >
          Aplicar
        </button>
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
      <select name={"filtros[#{@campo}]"} class="w-full border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5">
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
          class="w-0 flex-1 min-w-0 border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5"
        />
        <span class="text-gray-400 text-xs">–</span>
        <input
          type={@tipo_input}
          name={"filtros[#{@campo}_hasta]"}
          value={@valores["#{@campo}_hasta"]}
          placeholder="Hasta"
          phx-debounce="400"
          class="w-0 flex-1 min-w-0 border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5"
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
        class="w-full border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5"
      />
    </div>
    """
  end
end
