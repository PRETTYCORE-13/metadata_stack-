defmodule MetadataAppWeb.CatalogoLive do
  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.MetaStateEngine
  alias MetadataApp.MetaConsultas
  alias MetadataApp.Permissions
  alias MetadataApp.Autenticacion.Scope
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
      # get_connect_info/2 solo existe durante mount/3 (ver roadmap #6) --
      # se calcula UNA vez acá y se guarda en assigns para que cualquier
      # handle_event que dispare un crear/actualizar/eliminar lo reuse.
      |> assign(:contexto_auditoria, MetadataAppWeb.AuditoriaContexto.desde_socket(socket))

    case MetaSchemaContext.obtener_header_por_nav(nav) do
      nil ->
        {:ok,
         socket
         |> assign(:current_page, nav)
         |> assign(:encontrado?, false)}

      header ->
        if autorizado_para_leer?(socket.assigns[:current_scope], header.schema_context_name) do
          if header.schema_context_type == 3 do
            montar_consulta(socket, header)
          else
            montar_catalogo(socket, header)
          end
        else
          {:ok,
           socket
           |> put_flash(:error, "No tenés permiso para acceder a esto.")
           |> redirect(to: ~p"/")}
        end
    end
  end

  # El árbol del sidebar ya se poda por "leer" (menu_layout.ex,
  # podar_menu_por_permisos/1), pero eso solo oculta el link — no bloquea
  # entrar directo por URL. `/*ruta` es un catch-all genérico sin
  # `on_mount {Autorizacion, {recurso, accion}}` posible (el recurso es
  # dinámico, recién se conoce acá adentro tras resolver el header por
  # nav), así que el chequeo va a mano, mismo criterio deny-by-default que
  # el resto de RBAC: sin scope resuelto (no autenticado / sin empresa
  # activa), no autorizado.
  defp autorizado_para_leer?(%Scope{} = scope, recurso), do: Permissions.can?(scope, "leer", recurso)
  defp autorizado_para_leer?(_sin_scope, _recurso), do: false

  defp montar_catalogo(socket, header) do
    modulo = MetaSchemaContext.modulo_por_nombre(header.schema_context_name)
    es_detalle? = not is_nil(header.schema_encabezado_id)

    # Mismo criterio que ya usa el drawer de edición de FichaLive:
    # campos_editables/2 de la transición "alta" — si el catálogo no
    # adoptó el motor de estados, devuelve todos los campos (fail-open,
    # retrocompatible); si adoptó pero no tiene "alta" configurada,
    # devuelve [] y el botón de alta simplemente no aparece.
    campos_alta =
      if modulo && not es_detalle? do
        MetaStateEngine.campos_editables(header.schema_context_name, MetaStateEngine.transicion_alta(header.schema_context_name))
      else
        []
      end

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
     |> assign(:mostrar_trn?, header.schema_es_transaccional)
     |> assign(:modulo, modulo)
     |> assign(:es_detalle?, es_detalle?)
     |> assign(:campos_alta, campos_alta)
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

  # Consulta Ecto (schema_context_type: 3): reporte de solo lectura, sin
  # motor de estados/TRN/maestro-detalle/alta — reusa el mismo render de
  # tabla + panel de filtros que un catálogo normal (columna_desde_campo/1
  # traduce cada campo de la consulta al mismo shape %{schema_context_field:,
  # schema_context_properties:} que ya entienden panel_filtros/1,
  # filtro_columna/1 y construir_filtros_ecto/2, sin duplicar nada de eso).
  defp montar_consulta(socket, header) do
    consulta = MetaConsultas.obtener_por_header_id(header.id)

    columnas =
      consulta.campos
      |> Enum.filter(&(Map.get(&1, "visible") == true))
      |> Enum.sort_by(&Map.get(&1, "orden", 0))
      |> Enum.map(&columna_desde_campo_consulta/1)

    {:ok,
     socket
     |> assign(:current_page, header.schema_context_name)
     |> assign(:encontrado?, true)
     |> assign(:es_consulta?, true)
     |> assign(:label, header.schema_context_label)
     |> assign(:consulta, consulta)
     |> assign(:columnas, columnas)
     |> assign(:pagina, 1)
     |> assign(:filtros, %{})
     |> assign(:filtros_activos, [])
     |> assign(:selector_campo_abierto, false)
     |> assign(:busqueda_campo_filtro, "")
     |> assign(:busqueda_general, "")
     |> assign(:mostrar_filtros, false)
     |> assign(:totales, %{})
     |> cargar_filas()}
  end

  defp columna_desde_campo_consulta(campo) do
    %{
      schema_context_field: campo["campo"],
      schema_context_properties: %{"etiqueta" => campo["etiqueta"], "tipo" => campo["tipo"] || "string"},
      totalizar: campo["totalizar"] == true,
      catalogo: campo["catalogo"],
      # `schema_context_field` (crudo) sigue siendo lo que arman los
      # filtros/búsqueda (MetaConsultas.aplicar_filtros/4 lo resuelve
      # contra consulta.campos) — `clave` es la clave namespaced bajo la
      # que MetaConsultas.ejecutar/4 expone el VALOR en cada fila
      # (necesaria desde que hay más de una tabla: dos campos del mismo
      # nombre en tablas distintas no pueden compartir la misma clave).
      clave: MetaConsultas.clave_campo(campo)
    }
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
  defp cargar_filas(%{assigns: %{es_consulta?: true}} = socket), do: cargar_filas_consulta(socket)
  defp cargar_filas(socket), do: cargar_filas_catalogo(socket)

  # Mismo criterio de 2 pasos que un catálogo normal: primero contar/3 (sin
  # paginar) para saber @total_paginas y calcular el offset correcto, recién
  # después pedir la página con ese offset — MetaConsultas.ejecutar/4 también
  # devuelve un total_filas propio (para @totales, calculado sobre TODAS las
  # filas filtradas, no solo la página), pero ese no sirve para el offset
  # porque en ese punto todavía no lo conocemos.
  defp cargar_filas_consulta(socket) do
    %{consulta: consulta, columnas: columnas, filtros: filtros, busqueda_general: busqueda_general} = socket.assigns

    filtros_ecto = construir_filtros_ecto(filtros, columnas)
    campos_busqueda = Enum.map(columnas, & &1.schema_context_field)
    busqueda = {busqueda_general, campos_busqueda}

    total_filas = MetaConsultas.contar(consulta, filtros_ecto, busqueda)
    total_paginas = max(ceil(total_filas / @por_pagina), 1)
    pagina = socket.assigns.pagina |> max(1) |> min(total_paginas)
    offset = (pagina - 1) * @por_pagina

    %{filas: filas, totales: totales} =
      MetaConsultas.ejecutar(consulta, filtros_ecto, [limit: @por_pagina, offset: offset], busqueda)

    socket
    |> assign(:filas, filas)
    |> assign(:totales, totales)
    |> assign(:pagina, pagina)
    |> assign(:total_paginas, total_paginas)
    |> assign(:total_filas, total_filas)
    |> assign(:inicio, if(total_filas == 0, do: 0, else: offset + 1))
    |> assign(:fin, min(offset + @por_pagina, total_filas))
  end

  defp cargar_filas_catalogo(socket) do
    %{
      modulo: modulo,
      current_page: catalogo,
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

      registros = CatalogoGenerico.listar(modulo, filtros_ecto, [limit: @por_pagina, offset: offset], busqueda)
      acompanamiento = CatalogoGenerico.mapa_acompanamiento(catalogo, registros)

      filas = Enum.map(registros, &CatalogoGenerico.serializar(&1, estados_por_id, acompanamiento))

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

  def render(%{es_consulta?: true} = assigns) do
    ~H"""
    <div class="p-6">
      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-5">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-4">
          <div class="flex items-center gap-2">
            <span class="material-symbols-outlined text-purple-600" title="Consulta Ecto (solo lectura)">search</span>
            <h1 class="text-xl font-bold text-gray-900">{@label}</h1>
          </div>

          <span class="text-xs font-medium text-gray-500 bg-gray-100 rounded-full px-3 py-1 self-start sm:self-auto">
            {@inicio}-{@fin} de {@total_filas}
          </span>
        </div>

        <div class="flex items-center gap-2 flex-wrap mb-4">
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
          <.panel_campos campos={campos_selector(@columnas)} tabla_id="tabla-catalogo" />
        </div>

        <div class="overflow-x-auto rounded-xl border border-gray-200">
          <table id="tabla-catalogo" class="min-w-full divide-y divide-gray-200 text-xs">
            <thead class="bg-gray-50">
              <tr>
                <%= for columna <- @columnas do %>
                  <th data-col={col_key(columna)} class={["px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide", alineacion_columna(columna)]}>
                    {columna.schema_context_properties["etiqueta"]}
                    <span :if={@consulta.joins != []} class="block text-[9px] font-normal normal-case text-gray-400">{columna.catalogo}</span>
                  </th>
                <% end %>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <%= for fila <- @filas do %>
                <tr class="hover:bg-purple-50/60 transition-colors">
                  <%= for columna <- @columnas do %>
                    <% valor = Map.get(fila, columna.clave) %>
                    <td data-col={col_key(columna)} class={[
                      "px-4 py-1.5 text-[10px] text-gray-700",
                      alineacion_columna(columna)
                    ]}>
                      {formatear_celda(valor)}
                    </td>
                  <% end %>
                </tr>
              <% end %>
              <%= if @filas == [] do %>
                <tr>
                  <td class="px-4 py-10 text-center text-gray-400 text-sm" colspan={max(length(@columnas), 1)}>
                    Sin registros todavía
                  </td>
                </tr>
              <% end %>
            </tbody>
            <tfoot :if={@totales != %{}} class="bg-purple-50 border-t-2 border-purple-200 font-bold">
              <tr>
                <%= for columna <- @columnas do %>
                  <td data-col={col_key(columna)} class={["px-4 py-2 text-[10px] text-purple-900", alineacion_columna(columna)]}>
                    <%= if Map.get(columna, :totalizar) do %>
                      {formatear_celda(Map.get(@totales, columna.clave))}
                    <% end %>
                  </td>
                <% end %>
              </tr>
            </tfoot>
          </table>
        </div>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="p-6">
      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-5">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-4">
          <h1 class="text-xl font-bold text-gray-900">{@label}</h1>

          <div class="flex items-center gap-2 flex-wrap">
            <.link :if={@campos_alta != []} navigate={"/registro/#{@current_page}/nuevo"}
              aria-label="Nuevo registro"
              class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                <line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" />
              </svg>
              <span class="hidden sm:inline">Nuevo registro</span>
            </.link>
            <span class="text-xs font-medium text-gray-500 bg-gray-100 rounded-full px-3 py-1">
              {@inicio}-{@fin} de {@total_filas}
            </span>
            <div class="flex items-center gap-1 bg-gray-50 border border-gray-200 rounded-lg p-0.5">
              <button
                type="button"
                phx-click="pagina_anterior"
                disabled={@pagina <= 1}
                aria-label="Página anterior"
                class="w-9 h-9 sm:w-7 sm:h-7 flex items-center justify-center rounded-md text-gray-600 hover:bg-white hover:shadow-sm disabled:opacity-30 disabled:cursor-not-allowed disabled:hover:bg-transparent disabled:hover:shadow-none transition"
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
                class="w-9 h-9 sm:w-7 sm:h-7 flex items-center justify-center rounded-md text-gray-600 hover:bg-white hover:shadow-sm disabled:opacity-30 disabled:cursor-not-allowed disabled:hover:bg-transparent disabled:hover:shadow-none transition"
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                  <polyline points="9 18 15 12 9 6" />
                </svg>
              </button>
            </div>
          </div>
        </div>

        <div class="flex items-center gap-2 flex-wrap mb-4">
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
          <.panel_campos campos={campos_selector(@columnas, @mostrar_estado?, @mostrar_trn?)} tabla_id="tabla-catalogo" />
        </div>

        <div class="overflow-x-auto rounded-xl border border-gray-200">
          <table id="tabla-catalogo" class="min-w-full divide-y divide-gray-200 text-xs">
            <thead class="bg-gray-50">
              <tr>
                <th data-col="id" class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">ID</th>
                <%= for columna <- @columnas do %>
                  <th data-col={col_key(columna)} class={[
                    "px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide",
                    alineacion_columna(columna)
                  ]}>
                    <span class="inline-flex items-center gap-1">
                      {columna.schema_context_properties["etiqueta"]}
                      <%= if columna.schema_context_properties["tipo"] == "referencia" do %>
                        <span class="material-symbols-outlined text-blue-500" style="font-size: 13px" title={"Relación con #{columna.schema_context_properties["catalogo"]}"}>link</span>
                      <% end %>
                    </span>
                  </th>
                <% end %>
                <%= if @mostrar_estado? do %>
                  <th data-col="estado" class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Estado</th>
                <% end %>
                <%= if @mostrar_trn? do %>
                  <th data-col="trn" class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">TRN</th>
                <% end %>
                <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide"></th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <%= for fila <- @filas do %>
                <tr class="hover:bg-purple-50/60 transition-colors cursor-pointer"
                  ondblclick={"window.location='/registro/#{@current_page}/#{fila.id}'"}>
                  <td data-col="id" class="px-4 py-1.5 text-[10px] text-gray-700">
                    {fila.id}
                  </td>
                  <%= for columna <- @columnas do %>
                    <% valor = Map.get(fila, String.to_existing_atom(columna.schema_context_field)) %>
                    <td data-col={col_key(columna)} class={[
                      "px-4 py-1.5 text-[10px]",
                      alineacion_columna(columna),
                      if(is_map(valor) and not is_struct(valor), do: "text-blue-700 font-medium", else: "text-gray-700")
                    ]}>
                      {formatear_celda(valor)}
                    </td>
                  <% end %>
                  <%= if @mostrar_estado? do %>
                    <td data-col="estado" class="px-4 py-1.5 text-[10px] text-gray-700">{Map.get(fila, :estado_nombre)}</td>
                  <% end %>
                  <%= if @mostrar_trn? do %>
                    <td data-col="trn" class="px-4 py-1.5 text-[10px] text-gray-700 font-mono" title={Map.get(fila, :ulid)}>{Map.get(fila, :trn)}</td>
                  <% end %>
                  <td class="px-4 py-1.5 text-xs text-right">
                    <.link navigate={"/registro/#{@current_page}/#{fila.id}"}
                      title="Ver ficha 360°"
                      class="inline-flex items-center justify-center w-6 h-6 rounded-md text-gray-400 hover:bg-purple-50 hover:text-purple-700">
                      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                        <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8Z" /><circle cx="12" cy="12" r="3" />
                      </svg>
                    </.link>
                  </td>
                </tr>
              <% end %>
              <%= if @filas == [] do %>
                <tr>
                  <td
                    class="px-4 py-10 text-center text-gray-400 text-sm"
                    colspan={2 + (if @mostrar_trn?, do: 1, else: 0) + length(@columnas) + if @mostrar_estado?, do: 1, else: 0}
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

  # Identificador de columna para el selector de campos (data-col en
  # <th>/<td>, ver panel_campos/1 y el hook SelectorCampos en app.js).
  # Una consulta con JOIN puede repetir el mismo schema_context_field en
  # más de un catálogo (ej. "nombre" en dos tablas distintas) — ahí hace
  # falta la clave namespaced (:clave, ver columna_desde_campo_consulta/1)
  # para no confundir/ocultar la columna equivocada; un catálogo normal no
  # tiene :clave y usa el campo crudo, que ya es único.
  defp col_key(columna), do: Map.get(columna, :clave) || columna.schema_context_field

  # Lista %{clave:, etiqueta:} para el selector de campos (panel_campos/1)
  # — SOLO los campos de negocio (meta_schema_detail). La variante /3 le
  # suma ID/Estado/TRN, las columnas "estructurales" que arma esta misma
  # vista (no vienen de meta_schema_detail, así que col_key/1 no las
  # conoce) — en el mismo orden en que aparecen en la tabla, para que la
  # lista del popover se lea igual que las columnas de izquierda a
  # derecha. La columna de Acciones (el link a la Ficha 360°) queda
  # afuera a propósito: no es un campo, es un botón.
  defp campos_selector(columnas) do
    Enum.map(columnas, &%{clave: col_key(&1), etiqueta: &1.schema_context_properties["etiqueta"]})
  end

  defp campos_selector(columnas, mostrar_estado?, mostrar_trn?) do
    [%{clave: "id", etiqueta: "ID"}] ++
      campos_selector(columnas) ++
      (if mostrar_estado?, do: [%{clave: "estado", etiqueta: "Estado"}], else: []) ++
      (if mostrar_trn?, do: [%{clave: "trn", etiqueta: "TRN"}], else: [])
  end

  # Un campo tipo "referencia" con campos de acompañamiento configurados
  # llega acá como objeto anidado (%{id: 1, razon_social: "..."}), no como
  # escalar — se muestra el resumen legible (sin el id), no el mapa crudo.
  # `when not is_struct(mapa)` es necesario: un valor tipo Decimal/Date/
  # DateTime también hace match contra `%{}` (son structs = mapas), y sin
  # excluirlos acá se les destripaban los campos internos en vez de
  # mostrarse como el escalar que son.
  defp formatear_celda(%{} = mapa) when not is_struct(mapa) do
    mapa
    |> Map.delete(:id)
    |> Map.values()
    |> Enum.map_join(" · ", &(if is_nil(&1), do: "", else: to_string(&1)))
  end

  defp formatear_celda(valor), do: valor

  # Selector de columnas visibles ("Campos") — a propósito 100% del lado
  # del cliente (JS puro, ver hook SelectorCampos en app.js), sin un solo
  # phx-click al servidor: es puramente visual (oculta/muestra <th>/<td>
  # por CSS), no cambia @columnas ni la query real, así que no tiene
  # sentido pagar un roundtrip por cada tilde. phx-update="ignore" porque
  # @columnas no cambia durante la vida del mount (filtros/búsqueda/
  # paginación no la tocan) — sin esto, cualquier re-render de LiveView
  # pisaría el estado de los checkboxes que ya sincronizó el hook.
  # `campos` es una lista %{clave:, etiqueta:} ya armada por
  # campos_selector/1-3 — incluye tanto las columnas de negocio como,
  # cuando aplica, las estructurales (ID/Estado/TRN), en el mismo orden
  # en que aparecen en la tabla.
  attr :campos, :list, required: true
  attr :tabla_id, :string, required: true

  defp panel_campos(assigns) do
    ~H"""
    <div class="relative" id={"selector-campos-" <> @tabla_id} phx-hook="SelectorCampos" phx-update="ignore" data-tabla={@tabla_id}>
      <button
        type="button"
        phx-click={JS.toggle(to: "#campos-popover-" <> @tabla_id)}
        class="flex items-center gap-1.5 border border-gray-300 rounded-lg px-3 py-2 text-sm font-semibold text-gray-600 hover:bg-gray-50 whitespace-nowrap"
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <line x1="4" y1="6" x2="20" y2="6" /><circle cx="9" cy="6" r="2" fill="currentColor" stroke="none" />
          <line x1="4" y1="12" x2="20" y2="12" /><circle cx="15" cy="12" r="2" fill="currentColor" stroke="none" />
          <line x1="4" y1="18" x2="20" y2="18" /><circle cx="11" cy="18" r="2" fill="currentColor" stroke="none" />
        </svg>
        Campos
      </button>

      <div
        id={"campos-popover-" <> @tabla_id}
        class="hidden absolute right-0 top-full mt-2 w-72 max-h-[70vh] bg-white rounded-xl shadow-xl border border-gray-200 z-50 flex flex-col"
        phx-click-away={JS.hide()}
      >
        <div class="flex items-center justify-between px-4 py-2.5 border-b border-gray-200">
          <h2 class="text-sm font-bold text-gray-900">Campos</h2>
          <button
            type="button"
            phx-click={JS.hide(to: "#campos-popover-" <> @tabla_id)}
            aria-label="Cerrar selector de campos"
            class="w-6 h-6 flex items-center justify-center rounded-full text-gray-500 hover:bg-gray-100"
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        </div>

        <div class="px-4 py-2 border-b border-gray-200">
          <input
            type="text"
            data-buscador-campo
            placeholder="Buscar campo..."
            class="w-full border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-purple-500/30 focus:border-purple-500"
          />
        </div>

        <div class="flex items-center gap-2 px-4 py-2 border-b border-gray-200">
          <button type="button" data-accion="seleccionar-todos" class="text-xs font-semibold text-purple-700 hover:underline">
            Seleccionar todos
          </button>
          <span class="text-gray-300">·</span>
          <button type="button" data-accion="deseleccionar-todos" class="text-xs font-semibold text-purple-700 hover:underline">
            Deseleccionar todos
          </button>
        </div>

        <div class="overflow-y-auto py-1 flex-1" data-lista-campos>
          <%= for campo <- @campos do %>
            <div data-fila-campo data-etiqueta={campo.etiqueta} class="flex items-center gap-1.5 px-2 py-1.5 text-xs text-gray-700 hover:bg-gray-50">
              <span class="jal-manija flex-shrink-0 flex items-center justify-center w-4 h-4 text-gray-300 hover:text-gray-500 cursor-grab active:cursor-grabbing" title="Arrastrar para reordenar">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor">
                  <circle cx="8" cy="6" r="1.6" /><circle cx="16" cy="6" r="1.6" />
                  <circle cx="8" cy="12" r="1.6" /><circle cx="16" cy="12" r="1.6" />
                  <circle cx="8" cy="18" r="1.6" /><circle cx="16" cy="18" r="1.6" />
                </svg>
              </span>
              <label class="flex items-center gap-2 flex-1 min-w-0 cursor-pointer">
                <input type="checkbox" checked data-campo={campo.clave} class="accent-purple-600 flex-shrink-0" />
                <span class="truncate">{campo.etiqueta}</span>
              </label>
            </div>
          <% end %>
          <%= if @campos == [] do %>
            <p class="px-4 py-3 text-xs text-gray-400">No hay campos.</p>
          <% end %>
        </div>

        <div class="px-4 py-2.5 border-t border-gray-200">
          <button type="button" data-accion="limpiar" class="w-full text-xs font-semibold text-gray-500 hover:text-gray-800 px-2 py-1">
            Limpiar filtro de campos (mostrar todos)
          </button>
        </div>
      </div>
    </div>
    """
  end

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
