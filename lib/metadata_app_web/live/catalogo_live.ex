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

        # Catálogo Maestro-Detalle (Fase 5): catálogos detalle de ESTE
        # header, con sus propios campos visibles/ordenados (mismo criterio
        # que `columnas` arriba) — [] para la enorme mayoría de catálogos,
        # que siguen sin ningún cambio de comportamiento.
        catalogos_detalle =
          header.id
          |> MetaSchemaContext.listar_catalogos_detalle()
          |> Enum.map(fn h ->
            columnas_detalle =
              h.schema_context_name
              |> MetaSchemaContext.listar_detalles()
              |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
              |> Enum.filter(&get_in(&1, [:schema_context_properties, "visible"]))
              |> Enum.sort_by(&get_in(&1, [:schema_context_properties, "orden"]))

            %{nombre: h.schema_context_name, etiqueta: h.schema_context_label, columnas: columnas_detalle}
          end)

        {:ok,
         socket
         |> assign(:current_page, header.schema_context_name)
         |> assign(:encontrado?, true)
         |> assign(:label, header.schema_context_label)
         |> assign(:columnas, columnas)
         |> assign(:mostrar_estado?, estados_por_id != %{})
         |> assign(:mostrar_trn?, header.schema_es_transaccional)
         |> assign(:modulo, modulo)
         |> assign(:estados_por_id, estados_por_id)
         |> assign(:pagina, 1)
         |> assign(:filtros, %{})
         |> assign(:filtros_activos, [])
         |> assign(:selector_campo_abierto, false)
         |> assign(:busqueda_campo_filtro, "")
         |> assign(:busqueda_general, "")
         |> assign(:mostrar_filtros, false)
         |> assign(:catalogos_detalle, catalogos_detalle)
         |> assign(:es_maestro?, catalogos_detalle != [])
         |> assign(:detalle_modal, nil)
         |> assign(:detalle_renglones, %{})
         |> assign(:detalle_seleccion, %{})
         |> assign(:detalle_nuevo_renglon_form, nil)
         |> assign(:detalle_form_error, nil)
         |> assign(:detalle_error, nil)
         |> cargar_filas()}
    end
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, socket.assigns.current_page)
  end

  # --- Catálogo Maestro-Detalle (Fase 5): modal encabezado + renglones ------

  def handle_event("abrir_detalle", %{"id" => id}, socket) do
    {:noreply, cargar_detalle_modal(socket, String.to_integer(id))}
  end

  def handle_event("cerrar_detalle", _params, socket) do
    {:noreply,
     socket
     |> assign(:detalle_modal, nil)
     |> assign(:detalle_renglones, %{})
     |> assign(:detalle_seleccion, %{})
     |> assign(:detalle_nuevo_renglon_form, nil)
     |> assign(:detalle_form_error, nil)
     |> assign(:detalle_error, nil)}
  end

  def handle_event("toggle_renglon", %{"catalogo" => catalogo, "renglon_id" => renglon_id}, socket) do
    renglon_id = String.to_integer(renglon_id)

    {:noreply,
     update(socket, :detalle_seleccion, fn seleccion ->
       Map.update(seleccion, catalogo, MapSet.new([renglon_id]), fn set ->
         if MapSet.member?(set, renglon_id), do: MapSet.delete(set, renglon_id), else: MapSet.put(set, renglon_id)
       end)
     end)}
  end

  def handle_event("abrir_form_renglon", %{"catalogo" => catalogo}, socket) do
    {:noreply, socket |> assign(:detalle_nuevo_renglon_form, catalogo) |> assign(:detalle_form_error, nil)}
  end

  def handle_event("cancelar_form_renglon", _params, socket) do
    {:noreply, socket |> assign(:detalle_nuevo_renglon_form, nil) |> assign(:detalle_form_error, nil)}
  end

  # Sin borrar/editar acá a propósito (R12/R13 del requerimiento): un
  # renglón nace y después solo se mueve por transición — nunca se
  # soft-deletea ni se edita libre desde esta grilla.
  def handle_event("guardar_renglon", %{"catalogo" => catalogo} = params, socket) do
    campos_attrs = Map.get(params, "campos", %{})
    detalle_modulo = MetaSchemaContext.modulo_por_nombre(catalogo)
    encabezado_id = socket.assigns.detalle_modal.registro.id
    attrs = Map.put(campos_attrs, "encabezado_id", encabezado_id)

    case CatalogoGenerico.crear(detalle_modulo, attrs) do
      {:ok, _renglon} ->
        {:noreply,
         socket
         |> assign(:detalle_nuevo_renglon_form, nil)
         |> assign(:detalle_form_error, nil)
         |> recargar_renglones(catalogo)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :detalle_form_error, resumen_errores_simple(changeset))}
    end
  end

  # renglones_payload: %{"catalogo" => [renglon_id, ...]} a partir de la
  # selección de checkboxes — solo mueve estado (Fase 2), sin edición de
  # campos por renglón desde esta pantalla todavía (posible extensión
  # futura, no pedida para esta fase).
  def handle_event("ejecutar_transicion_detalle", %{"accion" => accion}, socket) do
    %{modulo: modulo, detalle_modal: %{registro: registro}, detalle_seleccion: seleccion} = socket.assigns
    registro_struct = CatalogoGenerico.obtener!(modulo, registro.id)

    renglones_payload =
      seleccion
      |> Enum.reject(fn {_catalogo, set} -> MapSet.size(set) == 0 end)
      |> Map.new(fn {catalogo, set} -> {catalogo, MapSet.to_list(set)} end)

    case MetaStateEngine.ejecutar_transicion(registro_struct, accion, %{}, renglones: renglones_payload) do
      {:ok, _actualizado} ->
        {:noreply, socket |> assign(:detalle_error, nil) |> cargar_detalle_modal(registro.id)}

      {:error, razon} ->
        {:noreply, assign(socket, :detalle_error, formatear_error_transicion(razon))}
    end
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

  # Carga/recarga TODO el estado del modal (registro + transiciones
  # disponibles + renglones de cada catálogo detalle) desde cero — se usa
  # tanto para abrirlo como para refrescarlo después de ejecutar una
  # transición (Fase 2/3: el header y los renglones seleccionados ya
  # cambiaron de estado en la misma transacción atómica del motor).
  defp cargar_detalle_modal(socket, id) do
    %{modulo: modulo, estados_por_id: estados_por_id, catalogos_detalle: catalogos_detalle} = socket.assigns

    registro_struct = CatalogoGenerico.obtener!(modulo, id)
    registro = CatalogoGenerico.serializar(registro_struct, estados_por_id)
    transiciones = MetaStateEngine.transiciones_disponibles(registro_struct, %{})

    renglones =
      Map.new(catalogos_detalle, fn %{nombre: nombre} ->
        detalle_modulo = MetaSchemaContext.modulo_por_nombre(nombre)

        filas =
          detalle_modulo
          |> CatalogoGenerico.listar(%{"encabezado_id" => id})
          |> Enum.map(&CatalogoGenerico.serializar(&1, estados_por_id))

        {nombre, filas}
      end)

    socket
    |> assign(:detalle_modal, %{registro: registro, transiciones: transiciones})
    |> assign(:detalle_renglones, renglones)
    |> assign(:detalle_seleccion, Map.new(catalogos_detalle, &{&1.nombre, MapSet.new()}))
    |> assign(:detalle_nuevo_renglon_form, nil)
    |> assign(:detalle_form_error, nil)
  end

  defp recargar_renglones(socket, catalogo) do
    %{estados_por_id: estados_por_id, detalle_modal: %{registro: registro}} = socket.assigns
    detalle_modulo = MetaSchemaContext.modulo_por_nombre(catalogo)

    filas =
      detalle_modulo
      |> CatalogoGenerico.listar(%{"encabezado_id" => registro.id})
      |> Enum.map(&CatalogoGenerico.serializar(&1, estados_por_id))

    update(socket, :detalle_renglones, &Map.put(&1, catalogo, filas))
  end

  # Mismos desenlaces estructurados que ya traduce MetadataAppWeb.FallbackController
  # para la API HTTP — acá en texto plano para mostrar en el modal.
  defp formatear_error_transicion({:precondiciones, fallas}) do
    Enum.map_join(fallas, " | ", fn
      %{mensaje: msg, renglon: %{catalogo: cat, renglon_id: rid}} -> "#{cat} renglón #{rid}: #{msg}"
      %{mensaje: msg} -> msg
    end)
  end

  defp formatear_error_transicion(:conflicto_concurrencia),
    do: "El registro cambió mientras tenías el modal abierto — cerrá y volvé a abrir."

  defp formatear_error_transicion({:transicion_invalida, _}),
    do: "Esa transición ya no está disponible desde el estado actual — cerrá y volvé a abrir."

  defp formatear_error_transicion(%Ecto.Changeset{} = changeset), do: resumen_errores_simple(changeset)
  defp formatear_error_transicion({:postcondicion_fallida, _}), do: "Error interno, no se aplicó el cambio."
  defp formatear_error_transicion(_otro), do: "No se pudo ejecutar la transición."

  defp resumen_errores_simple(changeset), do: MetadataApp.MetaErrores.resumen(changeset)

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
                <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">ID</th>
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
                <%= if @mostrar_trn? do %>
                  <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">TRN</th>
                <% end %>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <%= for fila <- @filas do %>
                <tr class="hover:bg-purple-50/60 transition-colors">
                  <td class="px-4 py-1.5 text-xs text-gray-700">
                    <%= if @es_maestro? do %>
                      <button type="button" phx-click="abrir_detalle" phx-value-id={fila.id}
                        class="text-purple-700 font-semibold hover:underline">{fila.id}</button>
                    <% else %>
                      {fila.id}
                    <% end %>
                  </td>
                  <%= for columna <- @columnas do %>
                    <td class={["px-4 py-1.5 text-xs text-gray-700", alineacion_columna(columna)]}>
                      {Map.get(fila, String.to_existing_atom(columna.schema_context_field))}
                    </td>
                  <% end %>
                  <%= if @mostrar_estado? do %>
                    <td class="px-4 py-1.5 text-xs text-gray-700">{Map.get(fila, :estado_nombre)}</td>
                  <% end %>
                  <%= if @mostrar_trn? do %>
                    <td class="px-4 py-1.5 text-xs text-gray-700 font-mono" title={Map.get(fila, :ulid)}>{Map.get(fila, :trn)}</td>
                  <% end %>
                </tr>
              <% end %>
              <%= if @filas == [] do %>
                <tr>
                  <td
                    class="px-4 py-10 text-center text-gray-400 text-sm"
                    colspan={1 + (if @mostrar_trn?, do: 1, else: 0) + length(@columnas) + if @mostrar_estado?, do: 1, else: 0}
                  >
                    Sin registros todavía
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

      <.detalle_modal :if={@detalle_modal} modal={@detalle_modal} renglones={@detalle_renglones}
        catalogos_detalle={@catalogos_detalle} seleccion={@detalle_seleccion}
        nuevo_renglon_form={@detalle_nuevo_renglon_form} form_error={@detalle_form_error} error={@detalle_error}
        header_columnas={@columnas} estados_por_id={@estados_por_id} label={@label} />
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

  # --- Catálogo Maestro-Detalle (Fase 5): modal encabezado + renglones -----
  # Mismo patrón visual que los modales de BcMotorLive (overlay fixed +
  # tarjeta blanca centrada) — sin ruta propia, popup interno sobre el
  # listado (decisión explícita: no pantalla aparte).

  attr :modal, :map, required: true
  attr :renglones, :map, required: true
  attr :catalogos_detalle, :list, required: true
  attr :seleccion, :map, required: true
  attr :nuevo_renglon_form, :string, default: nil
  attr :form_error, :string, default: nil
  attr :error, :string, default: nil
  attr :header_columnas, :list, required: true
  attr :estados_por_id, :map, required: true
  attr :label, :string, required: true

  defp detalle_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-4xl w-full max-h-[90vh] overflow-y-auto text-xs">
        <div class="flex items-center justify-between px-4 py-3 border-b border-gray-200 sticky top-0 bg-white rounded-t-xl">
          <div>
            <h2 class="text-sm font-bold text-gray-900">{@label} #{@modal.registro.id}</h2>
            <span class="text-gray-500">
              Estado: <strong class="text-gray-800">{Map.get(@modal.registro, :estado_nombre) || "—"}</strong>
            </span>
          </div>
          <button type="button" phx-click="cerrar_detalle" aria-label="Cerrar"
            class="w-7 h-7 flex items-center justify-center rounded-full text-gray-500 hover:bg-gray-100">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        </div>

        <div class="p-4 space-y-4">
          <div :if={@error} class="bg-red-50 text-red-700 rounded-lg px-3 py-2">{@error}</div>

          <div class="border border-gray-200 rounded-lg p-3">
            <div class="grid grid-cols-3 gap-2">
              <div :for={col <- @header_columnas}>
                <span class="block text-gray-400">{col.schema_context_properties["etiqueta"]}</span>
                <span class="text-gray-900 font-medium">
                  {Map.get(@modal.registro, String.to_existing_atom(col.schema_context_field))}
                </span>
              </div>
            </div>
          </div>

          <div :if={@modal.transiciones != []} class="flex flex-wrap gap-2">
            <button :for={t <- @modal.transiciones} type="button"
              phx-click="ejecutar_transicion_detalle" phx-value-accion={t.accion} disabled={!t.disponible}
              title={if !t.disponible, do: Enum.map_join(t.razones, "; ", & &1.mensaje)}
              class={[
                "px-3 py-1.5 rounded-lg font-semibold transition-colors",
                t.disponible && "bg-purple-600 text-white hover:bg-purple-700",
                !t.disponible && "bg-gray-100 text-gray-400 cursor-not-allowed"
              ]}>
              {t.etiqueta}
            </button>
          </div>
          <p :if={@modal.transiciones == []} class="text-gray-400">Sin transiciones disponibles desde este estado.</p>

          <div :for={cat <- @catalogos_detalle} class="border border-gray-200 rounded-lg">
            <div class="flex items-center justify-between px-3 py-2 border-b border-gray-200 bg-gray-50 rounded-t-lg">
              <span class="font-bold text-gray-700">{cat.etiqueta}</span>
              <button type="button" phx-click="abrir_form_renglon" phx-value-catalogo={cat.nombre}
                class="text-purple-700 font-semibold hover:underline">+ Agregar renglón</button>
            </div>

            <div :if={@nuevo_renglon_form == cat.nombre} class="px-3 py-2 border-b border-gray-100 bg-purple-50/40">
              <div :if={@form_error} class="bg-red-50 text-red-700 rounded px-2 py-1 mb-1.5">{@form_error}</div>
              <form phx-submit="guardar_renglon" class="grid grid-cols-3 gap-2 items-end">
                <input type="hidden" name="catalogo" value={cat.nombre} />
                <.campo_input :for={col <- cat.columnas} columna={col} />
                <div class="flex gap-1">
                  <button type="submit" class="px-2.5 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">
                    Guardar
                  </button>
                  <button type="button" phx-click="cancelar_form_renglon"
                    class="px-2.5 py-1.5 rounded-lg border border-gray-300 text-gray-600 hover:bg-gray-100">
                    Cancelar
                  </button>
                </div>
              </form>
            </div>

            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-100">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-2 py-1.5 w-6"></th>
                    <th class="px-2 py-1.5 text-left text-gray-500">#</th>
                    <th :for={col <- cat.columnas} class="px-2 py-1.5 text-left text-gray-500">
                      {col.schema_context_properties["etiqueta"]}
                    </th>
                    <th class="px-2 py-1.5 text-left text-gray-500">Estado</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-50">
                  <tr :for={r <- Map.get(@renglones, cat.nombre, [])}>
                    <td class="px-2 py-1">
                      <input type="checkbox" phx-click="toggle_renglon" phx-value-catalogo={cat.nombre}
                        phx-value-renglon_id={r.renglon_id}
                        checked={MapSet.member?(Map.get(@seleccion, cat.nombre, MapSet.new()), r.renglon_id)}
                        class="accent-purple-600" />
                    </td>
                    <td class="px-2 py-1 text-gray-500">{r.renglon_id}</td>
                    <td :for={col <- cat.columnas} class="px-2 py-1 text-gray-800">
                      {Map.get(r, String.to_existing_atom(col.schema_context_field))}
                    </td>
                    <td class="px-2 py-1 text-gray-600">{Map.get(@estados_por_id, r.estado_id) || "—"}</td>
                  </tr>
                  <tr :if={Map.get(@renglones, cat.nombre, []) == []}>
                    <td colspan={2 + length(cat.columnas)} class="px-2 py-4 text-center text-gray-400">
                      Sin renglones todavía.
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Input de un campo del form "+ Agregar renglón", según su tipo — mismo
  # criterio de dispatch que filtro_columna/1, adaptado a un valor único
  # (no rango) para crear, no filtrar.
  attr :columna, :map, required: true

  defp campo_input(%{columna: %{schema_context_properties: %{"tipo" => "boolean"}}} = assigns) do
    ~H"""
    <label class="flex items-center gap-1.5 mb-0.5">
      <input type="hidden" name={"campos[#{@columna.schema_context_field}]"} value="false" />
      <input type="checkbox" name={"campos[#{@columna.schema_context_field}]"} value="true" class="accent-purple-600" />
      {@columna.schema_context_properties["etiqueta"]}
    </label>
    """
  end

  defp campo_input(%{columna: %{schema_context_properties: %{"tipo" => "enum"}}} = assigns) do
    ~H"""
    <div>
      <label class="block text-gray-500 mb-0.5">{@columna.schema_context_properties["etiqueta"]}</label>
      <select name={"campos[#{@columna.schema_context_field}]"} required
        class="w-full border border-gray-300 rounded text-gray-900 px-2 py-1.5">
        <option :for={v <- @columna.schema_context_properties["valores"]} value={v}>{v}</option>
      </select>
    </div>
    """
  end

  defp campo_input(%{columna: %{schema_context_properties: %{"tipo" => tipo}}} = assigns)
       when tipo in ["integer", "decimal"] do
    assigns = assign(assigns, :step, if(tipo == "decimal", do: "any"))

    ~H"""
    <div>
      <label class="block text-gray-500 mb-0.5">{@columna.schema_context_properties["etiqueta"]}</label>
      <input type="number" step={@step} name={"campos[#{@columna.schema_context_field}]"} required
        class="w-full border border-gray-300 rounded text-gray-900 px-2 py-1.5" />
    </div>
    """
  end

  defp campo_input(%{columna: %{schema_context_properties: %{"tipo" => "date"}}} = assigns) do
    ~H"""
    <div>
      <label class="block text-gray-500 mb-0.5">{@columna.schema_context_properties["etiqueta"]}</label>
      <input type="date" name={"campos[#{@columna.schema_context_field}]"} required
        class="w-full border border-gray-300 rounded text-gray-900 px-2 py-1.5" />
    </div>
    """
  end

  # Default (string, referencia sin picker todavía — ver
  # project_frontend_referencia_ux, responsabilidad de Frontend a futuro).
  defp campo_input(assigns) do
    ~H"""
    <div>
      <label class="block text-gray-500 mb-0.5">{@columna.schema_context_properties["etiqueta"]}</label>
      <input type="text" name={"campos[#{@columna.schema_context_field}]"} required
        maxlength={@columna.schema_context_properties["longitud"]}
        class="w-full border border-gray-300 rounded text-gray-900 px-2 py-1.5" />
    </div>
    """
  end
end
