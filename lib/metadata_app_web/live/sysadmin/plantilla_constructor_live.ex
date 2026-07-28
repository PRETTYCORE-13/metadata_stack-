defmodule MetadataAppWeb.Sysadmin.PlantillaConstructorLive do
  @moduledoc """
  Constructor de plantillas: arma el árbol de componentes que `FichaLive`
  usa para renderizar el tab "Datos" de un catálogo en vez de la lista
  plana de siempre — ver `MetadataApp.MetaPlantillas` para el modelo de
  datos y los helpers de árbol que este LiveView llama.

  El lienzo soporta arrastrar y soltar real (hook `ListaOrdenable` en
  assets/js/app.js, sobre Sortable.js) — cada lista de hijos (la raíz y
  adentro de cada Sección) es su propio contenedor arrastrable, todas con
  el mismo `group`, así un componente se puede mover entre listas, no solo
  reordenar dentro de la misma.

  Los cambios de árbol (agregar/quitar/mover/editar propiedades) se hacen
  sobre `@definicion` en memoria; "Guardar" persiste, "Publicar" persiste y
  además marca esta plantilla como la única activa del catálogo.
  """

  use MetadataAppWeb, :live_view_admin

  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerico}
  alias MetadataApp.MetaPlantillas
  alias MetadataApp.MetaStateEngine
  alias MetadataAppWeb.AdminNav

  @tipos_estructura [
    {"seccion", "Sección"},
    {"fila", "Fila (2 columnas)"},
    {"pestanas", "Pestañas"},
    {"panel", "Panel"},
    {"divisor", "Divisor"},
    {"tabla", "Tabla relacionada"},
    {"campo_calculado", "Campo calculado"},
    {"autocompletar", "Autocompletar"},
    {"etiqueta", "Etiqueta"},
    {"alerta", "Alerta"},
    {"tarjeta", "Tarjeta"}
  ]

  # filtro => etiqueta del botón de paleta — el filtro en sí (qué tipos
  # reales de meta_schema_detail acepta) vive en MetaPlantillas.filtros_campo/0,
  # un solo lugar de verdad para no desincronizar paleta y validación.
  @tipos_campo [
    {"string", "Texto"},
    {"numero", "Número"},
    {"date", "Fecha"},
    {"enum", "Selección"},
    {"boolean", "Casilla"},
    {"referencia", "Catálogo"}
  ]

  def mount(%{"nombre" => nombre}, _session, socket) do
    socket = assign(socket, :sidebar_open, false) |> assign(:current_page, "sysadmin")

    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        {:ok, assign(socket, :encontrado?, false)}

      header ->
        campos =
          nombre
          |> MetaSchemaContext.listar_detalles()
          |> Enum.map(&MetaSchemaContext.serializar_detalle/1)

        catalogos_relacionables =
          nombre
          |> MetaSchemaContext.listar_dependientes()
          |> Enum.map(fn c -> {c, (MetaSchemaContext.obtener_header_por_nombre(c) || %{schema_context_label: c}).schema_context_label} end)

        # Para el panel de "Campo calculado" — CUALQUIER catálogo sirve para
        # SUM/COUNT/AVG/MIN/MAX o "{catalogo#id.campo}" (Formula.evaluar/2
        # no exige relación), así que acá se listan todos, no solo los
        # relacionados a este.
        catalogos_disponibles =
          MetaSchemaContext.listar_headers()
          |> Enum.reject(&(&1.schema_context_name == nombre))
          |> Enum.map(fn h ->
            campos_h =
              h.schema_context_name
              |> MetaSchemaContext.listar_detalles()
              |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
              |> Enum.filter(&get_in(&1, [:schema_context_properties, "visible"]))

            %{nombre: h.schema_context_name, etiqueta: h.schema_context_label, campos: campos_h}
          end)

        plantillas = MetaPlantillas.listar_plantillas(header.id)

        # Un registro real cualquiera del catálogo, para el link "Vista
        # previa" (abre su Ficha 360° forzando esta plantilla vía
        # ?plantilla_id=, sin publicarla — ver FichaLive.plantilla_a_mostrar/2).
        # nil si el catálogo no tiene módulo generado o está vacío: el botón
        # simplemente no aparece, no tiene sentido previsualizar sin datos.
        registro_muestra_id =
          case MetaSchemaContext.modulo_por_nombre(nombre) do
            nil -> nil
            modulo -> case CatalogoGenerico.listar(modulo, %{}, limit: 1) do
              [r] -> r.id
              [] -> nil
            end
          end

        # Nombres de estado reales del catálogo (para el <select> de valor
        # cuando la condición usa el pseudo-campo "__estado__") — evita que
        # quien diseña la plantilla tenga que escribir a mano "Publicado" y
        # arriesgarse a una mayúscula/tilde distinta que nunca matchee.
        estados =
          nombre
          |> MetaStateEngine.mapa_nombres_estados()
          |> Map.values()
          |> Enum.uniq()
          |> Enum.sort()

        {:ok,
         socket
         |> assign(:encontrado?, true)
         |> assign(:nombre, nombre)
         |> assign(:header, header)
         |> assign(:campos, campos)
         |> assign(:catalogos_relacionables, catalogos_relacionables)
         |> assign(:catalogos_disponibles, catalogos_disponibles)
         |> assign(:estados, estados)
         |> assign(:registro_muestra_id, registro_muestra_id)
         |> assign(:plantillas, plantillas)
         |> assign(:nodo_seleccionado_id, nil)
         |> assign(:mensaje, nil)
         |> seleccionar(List.first(plantillas))}
    end
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, socket.assigns.current_page)
  end

  def handle_event("nueva_plantilla", _params, socket) do
    n = length(socket.assigns.plantillas) + 1

    case MetaPlantillas.crear_plantilla(socket.assigns.header.id, %{"nombre" => "PostView #{n}", "estado" => "borrador"}) do
      {:ok, plantilla} ->
        plantillas = socket.assigns.plantillas ++ [plantilla]
        {:noreply, socket |> assign(:plantillas, plantillas) |> seleccionar(plantilla)}

      {:error, _changeset} ->
        {:noreply, assign(socket, :mensaje, {:error, "No se pudo crear el PostView."})}
    end
  end

  def handle_event("seleccionar_plantilla", %{"id" => id}, socket) do
    plantilla = Enum.find(socket.assigns.plantillas, &(&1.id == String.to_integer(id)))
    {:noreply, seleccionar(socket, plantilla)}
  end

  def handle_event("agregar", %{"tipo" => tipo}, socket) do
    nodo =
      case tipo do
        "fila" -> MetaPlantillas.nuevo_nodo_fila()
        "pestanas" -> MetaPlantillas.nuevo_nodo_pestanas()
        _ -> MetaPlantillas.nuevo_nodo(tipo)
      end

    definicion = MetaPlantillas.insertar_nodo(socket.assigns.definicion, contenedor_seleccionado(socket), nodo)

    {:noreply, socket |> assign(:definicion, definicion) |> assign(:nodo_seleccionado_id, nodo["id"])}
  end

  def handle_event("agregar_campo", %{"filtro" => filtro}, socket) do
    nodo = MetaPlantillas.nuevo_nodo_campo(filtro)
    definicion = MetaPlantillas.insertar_nodo(socket.assigns.definicion, contenedor_seleccionado(socket), nodo)

    {:noreply, socket |> assign(:definicion, definicion) |> assign(:nodo_seleccionado_id, nodo["id"])}
  end

  def handle_event("seleccionar_nodo", %{"id" => id}, socket) do
    {:noreply, assign(socket, :nodo_seleccionado_id, id)}
  end

  def handle_event("quitar_nodo", %{"id" => id}, socket) do
    definicion = MetaPlantillas.quitar_componente(socket.assigns.definicion, id)
    seleccionado = if socket.assigns.nodo_seleccionado_id == id, do: nil, else: socket.assigns.nodo_seleccionado_id

    {:noreply, socket |> assign(:definicion, definicion) |> assign(:nodo_seleccionado_id, seleccionado)}
  end

  def handle_event("mover_a", %{"id" => id, "contenedor_id" => contenedor_id, "index" => index}, socket) do
    contenedor_id = if contenedor_id in [nil, ""], do: nil, else: contenedor_id
    definicion = MetaPlantillas.mover_a(socket.assigns.definicion, id, contenedor_id, index)

    {:noreply, assign(socket, :definicion, definicion)}
  end

  def handle_event("actualizar_propiedad", params, socket) do
    id = socket.assigns.nodo_seleccionado_id
    propiedades = Map.drop(params, ["_target"])
    definicion = MetaPlantillas.actualizar_propiedades(socket.assigns.definicion, id, propiedades)

    {:noreply, assign(socket, :definicion, definicion)}
  end

  # Condición de visibilidad de CUALQUIER componente seleccionado — a
  # diferencia de actualizar_propiedad/2 (propiedades propias de cada tipo,
  # un form por tipo), este form es el mismo sin importar qué nodo esté
  # seleccionado, así que tiene su propio evento. "condicion" se guarda
  # como un mapa dentro de propiedades (o nil si no hay campo elegido) —
  # FichaLive.condicion_cumplida?/3 la evalúa contra el registro real.
  def handle_event("actualizar_condicion", params, socket) do
    id = socket.assigns.nodo_seleccionado_id
    condicion = condicion_desde_params(params)
    definicion = MetaPlantillas.actualizar_propiedades(socket.assigns.definicion, id, %{"condicion" => condicion})

    {:noreply, assign(socket, :definicion, definicion)}
  end

  def handle_event("guardar", _params, socket) do
    if plantilla_desactualizada?(socket) do
      {:noreply, assign(socket, :mensaje, {:conflicto, "Alguien más guardó cambios en este PostView mientras la tenías abierto."})}
    else
      case MetaPlantillas.actualizar_definicion(socket.assigns.plantilla, socket.assigns.definicion) do
        {:ok, plantilla} ->
          {:noreply,
           socket
           |> assign(:plantilla, plantilla)
           |> actualizar_en_lista(plantilla)
           |> assign(:mensaje, {:ok, "Guardado."})}

        {:error, _changeset} ->
          {:noreply, assign(socket, :mensaje, {:error, "No se pudo guardar."})}
      end
    end
  end

  # "Vista previa" guarda el borrador actual ANTES de abrir la pestaña
  # nueva — sin esto, el link apuntaba al id de la plantilla pero
  # FichaLive la lee de la base (obtener_plantilla!/1), así que cualquier
  # cambio hecho después del último "Guardar" explícito no se veía
  # reflejado (el mensaje "Guardado." de un guardado anterior se queda
  # pegado en pantalla y engaña). No hay forma de que el servidor abra una
  # pestaña nueva por su cuenta, así que guarda y recién después empuja
  # "abrir_vista_previa" al hook AbrirVistaPrevia (assets/js/app.js), que
  # hace el window.open — el mismo viaje de ida y vuelta que ya usa
  # ListaOrdenable para el drag-and-drop.
  def handle_event("vista_previa", _params, socket) do
    if plantilla_desactualizada?(socket) do
      {:noreply,
       socket
       |> assign(:mensaje, {:conflicto, "Alguien más guardó cambios en esta plantilla mientras la tenías abierta."})
       |> push_event("cancelar_vista_previa", %{})}
    else
      case MetaPlantillas.actualizar_definicion(socket.assigns.plantilla, socket.assigns.definicion) do
        {:ok, plantilla} ->
          url = "/registro/#{socket.assigns.nombre}/#{socket.assigns.registro_muestra_id}?plantilla_id=#{plantilla.id}"

          {:noreply,
           socket
           |> assign(:plantilla, plantilla)
           |> actualizar_en_lista(plantilla)
           |> assign(:mensaje, {:ok, "Guardado."})
           |> push_event("abrir_vista_previa", %{url: url})}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> assign(:mensaje, {:error, "No se pudo guardar."})
           |> push_event("cancelar_vista_previa", %{})}
      end
    end
  end

  def handle_event("publicar", _params, socket) do
    if plantilla_desactualizada?(socket) do
      {:noreply, assign(socket, :mensaje, {:conflicto, "Alguien más guardó cambios en este PostView mientras la tenías abierto."})}
    else
      with {:ok, guardada} <- MetaPlantillas.actualizar_definicion(socket.assigns.plantilla, socket.assigns.definicion),
           {:ok, publicada} <- MetaPlantillas.publicar_plantilla(guardada) do
        plantillas = Enum.map(socket.assigns.plantillas, &recargar_estado(&1, publicada))

        {:noreply,
         socket
         |> assign(:plantilla, publicada)
         |> assign(:plantillas, plantillas)
         |> assign(:mensaje, {:ok, "Publicada — ya es la que ve la Ficha 360° de este catálogo."})}
      else
        {:error, _} -> {:noreply, assign(socket, :mensaje, {:error, "No se pudo publicar."})}
      end
    end
  end

  # Recarga esta plantilla (y la lista, por si otra cambió de estado) desde
  # la base, descartando el borrador local — botón "Recargar" del banner de
  # conflicto.
  def handle_event("recargar_plantilla", _params, socket) do
    header_id = socket.assigns.header.id
    plantilla_fresca = MetaPlantillas.obtener_plantilla!(socket.assigns.plantilla.id)

    {:noreply,
     socket
     |> assign(:plantillas, MetaPlantillas.listar_plantillas(header_id))
     |> assign(:mensaje, nil)
     |> seleccionar(plantilla_fresca)}
  end

  defp seleccionar(socket, nil) do
    socket |> assign(:plantilla, nil) |> assign(:definicion, nil) |> assign(:nodo_seleccionado_id, nil)
  end

  defp seleccionar(socket, plantilla) do
    socket
    |> assign(:plantilla, plantilla)
    |> assign(:definicion, plantilla.definicion)
    |> assign(:nodo_seleccionado_id, nil)
  end

  # Si hay un nodo seleccionado Y es un contenedor (MetaPlantillas.tipos_contenedor/0
  # — Sección/Fila/Columna), los nuevos componentes entran ahí; si no, van a la raíz.
  defp contenedor_seleccionado(socket) do
    case socket.assigns.nodo_seleccionado_id do
      nil ->
        nil

      id ->
        nodo = MetaPlantillas.buscar_nodo(socket.assigns.definicion, id)
        if nodo && nodo["tipo"] in MetaPlantillas.tipos_contenedor(), do: id, else: nil
    end
  end

  # Chequeo de concurrencia best-effort (mismo criterio que ya usa FichaLive
  # para el drawer de edición de un registro): compara el update_guid que
  # esta pantalla tenía al cargar/guardar por última vez contra el que hay
  # ahora mismo en la base — si difieren, alguien más guardó esta misma
  # plantilla mientras la tenías abierta. No es un lock real (dos guardados
  # a la vez podrían pasar la comparación juntos), pero cubre el caso común
  # de dos pestañas/sesiones editando la misma plantilla en momentos
  # distintos, que hoy se pisaban en silencio.
  defp plantilla_desactualizada?(socket) do
    actual = MetaPlantillas.obtener_plantilla!(socket.assigns.plantilla.id)
    actual.update_guid != socket.assigns.plantilla.update_guid
  end

  defp condicion_desde_params(%{"campo" => campo}) when campo in [nil, ""], do: nil

  defp condicion_desde_params(params) do
    %{
      "campo" => params["campo"],
      "operador" => params["operador"] || "igual",
      "valor" => params["valor"] || ""
    }
  end

  defp actualizar_en_lista(socket, plantilla) do
    assign(socket, :plantillas, Enum.map(socket.assigns.plantillas, &(if &1.id == plantilla.id, do: plantilla, else: &1)))
  end

  defp recargar_estado(p, publicada) when p.id == publicada.id, do: publicada
  defp recargar_estado(p, _publicada), do: %{p | estado: "borrador"}

  def render(%{encontrado?: false} = assigns) do
    ~H"""
    <div class="p-8">
      <h1 class="text-xl font-bold">Catálogo no encontrado</h1>
    </div>
    """
  end

  def render(assigns) do
    assigns = assigns |> assign(:tipos_estructura, @tipos_estructura) |> assign(:tipos_campo, @tipos_campo)

    ~H"""
    <div class="p-6">
      <div class="flex items-center justify-between mb-4">
        <div>
          <h1 class="text-xl font-bold text-gray-900">PostView — {@header.schema_context_label}</h1>
          <p class="text-xs text-gray-500 mt-0.5">Diseña el tab "Datos" de la Ficha 360° de este catálogo.</p>
        </div>
        <div class="flex items-center gap-2">
          <select :if={@plantillas != []} phx-change="seleccionar_plantilla" name="id"
            class="border border-gray-300 rounded-lg text-sm px-2 py-1.5 text-gray-700">
            <option :for={p <- @plantillas} value={p.id} selected={@plantilla && @plantilla.id == p.id}>
              {p.nombre} · {p.estado}
            </option>
          </select>
          <span :if={@plantilla} class={[
            "text-[11px] font-semibold px-2 py-1 rounded-full whitespace-nowrap",
            @plantilla.estado == "publicada" && "bg-green-50 text-green-700",
            @plantilla.estado != "publicada" && "bg-gray-100 text-gray-500"
          ]}>
            {if @plantilla.estado == "publicada", do: "● Publicada", else: "○ Borrador"}
          </span>
          <div class="w-px h-5 bg-gray-200 mx-1"></div>
          <button type="button" phx-click="nueva_plantilla" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 text-xs font-semibold hover:bg-gray-50">
            + Nuevo PostView
          </button>
          <button :if={@plantilla && @registro_muestra_id} type="button" phx-click="vista_previa" phx-hook="AbrirVistaPrevia" id="btn-vista-previa"
            class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 text-xs font-semibold hover:bg-gray-50">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8Z" /><circle cx="12" cy="12" r="3" /></svg>
            Vista previa
          </button>
          <span :if={@plantilla && !@registro_muestra_id} class="text-[11px] text-gray-400" title="Este catálogo no tiene registros todavía">
            Sin registros para previsualizar
          </span>
          <button :if={@plantilla} type="button" phx-click="guardar" class="px-3 py-1.5 rounded-lg border border-purple-300 text-purple-700 text-xs font-semibold hover:bg-purple-50">
            Guardar
          </button>
          <button :if={@plantilla} type="button" phx-click="publicar" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700">
            Publicar
          </button>
        </div>
      </div>

      <div :if={@mensaje} class={[
        "text-xs rounded-lg px-3 py-2 mb-3 flex items-center justify-between gap-3",
        elem(@mensaje, 0) == :ok && "bg-green-50 text-green-700",
        elem(@mensaje, 0) == :error && "bg-red-50 text-red-700",
        elem(@mensaje, 0) == :conflicto && "bg-amber-50 text-amber-700"
      ]}>
        <span>{elem(@mensaje, 1)}</span>
        <button :if={elem(@mensaje, 0) == :conflicto} type="button" phx-click="recargar_plantilla" class="font-semibold whitespace-nowrap hover:underline">
          Recargar
        </button>
      </div>

      <div :if={is_nil(@plantilla)} class="bg-white border border-gray-200 rounded-xl p-10 text-center text-gray-400 text-sm">
        Este catálogo todavía no tiene ningún PostView. Creá uno para empezar.
      </div>

      <div :if={@plantilla} class="grid grid-cols-[180px_1fr_280px] gap-4">
        <div class="bg-white border border-gray-200 rounded-xl p-3">
          <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Estructura</div>
          <div class="flex flex-col gap-1.5 mb-4">
            <button :for={{tipo, etiqueta} <- @tipos_estructura} type="button" phx-click="agregar" phx-value-tipo={tipo}
              class="flex items-center gap-2 text-left px-2.5 py-1.5 rounded-lg border border-gray-200 text-xs font-semibold text-gray-600 hover:border-purple-400 hover:text-purple-700 hover:bg-purple-50/50">
              <.icono tipo={tipo} /> {etiqueta}
            </button>
          </div>
          <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Campos</div>
          <div class="flex flex-col gap-1.5">
            <button :for={{filtro, etiqueta} <- @tipos_campo} type="button" phx-click="agregar_campo" phx-value-filtro={filtro}
              class="flex items-center gap-2 text-left px-2.5 py-1.5 rounded-lg border border-gray-200 text-xs font-semibold text-gray-600 hover:border-purple-400 hover:text-purple-700 hover:bg-purple-50/50">
              <.icono tipo={filtro} /> {etiqueta}
            </button>
          </div>
        </div>

        <div class="bg-white border border-gray-200 rounded-xl p-4 min-h-[300px]">
          <div id="jal-lista-raiz" phx-hook="ListaOrdenable" data-contenedor-id="" class="min-h-[280px]">
            <.nodo_item :for={nodo <- @definicion["hijos"]} nodo={nodo} nivel={0} seleccionado_id={@nodo_seleccionado_id} />
          </div>
          <p :if={@definicion["hijos"] == []} class="text-center text-gray-400 text-sm py-10">
            Lienzo vacío — agregá un componente desde la paleta.
          </p>
        </div>

        <div class="bg-white border border-gray-200 rounded-xl p-3">
          <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Propiedades</div>
          <.panel_propiedades :if={@nodo_seleccionado_id} nodo={MetaPlantillas.buscar_nodo(@definicion, @nodo_seleccionado_id)} campos={@campos} catalogos_relacionables={@catalogos_relacionables} catalogos_disponibles={@catalogos_disponibles} />
          <p :if={!@nodo_seleccionado_id} class="text-xs text-gray-400">Seleccioná un componente del lienzo.</p>
          <.panel_condicion :if={@nodo_seleccionado_id} nodo={MetaPlantillas.buscar_nodo(@definicion, @nodo_seleccionado_id)} campos={@campos} estados={@estados} />
        </div>
      </div>
    </div>
    """
  end

  attr :nodo, :map, required: true
  attr :nivel, :integer, required: true
  attr :seleccionado_id, :string, default: nil

  defp nodo_item(assigns) do
    ~H"""
    <div id={"jal-nodo-" <> @nodo["id"]} data-id={@nodo["id"]} style={"margin-left: #{@nivel * 18}px"} class="mb-2">
      <div
        phx-click="seleccionar_nodo" phx-value-id={@nodo["id"]}
        class={[
          "flex items-center justify-between gap-2 px-2.5 py-1.5 rounded-lg border cursor-pointer text-xs",
          @seleccionado_id == @nodo["id"] && "border-purple-500 bg-purple-50",
          @seleccionado_id != @nodo["id"] && "border-gray-200 hover:border-gray-300"
        ]}
      >
        <div class="flex items-center gap-2 min-w-0">
          <svg class="jal-manija text-gray-300 hover:text-gray-500 cursor-grab flex-shrink-0" width="12" height="12" viewBox="0 0 24 24" fill="currentColor" title="Arrastrar para reordenar">
            <circle cx="8" cy="6" r="1.6" /><circle cx="16" cy="6" r="1.6" /><circle cx="8" cy="12" r="1.6" /><circle cx="16" cy="12" r="1.6" /><circle cx="8" cy="18" r="1.6" /><circle cx="16" cy="18" r="1.6" />
          </svg>
          <span class="text-gray-400 flex-shrink-0"><.icono tipo={icono_de_nodo(@nodo)} /></span>
          <span class="font-semibold text-gray-700 truncate">{etiqueta_nodo(@nodo)}</span>
        </div>
        <button type="button" phx-click="quitar_nodo" phx-value-id={@nodo["id"]} class="text-red-400 hover:text-red-600 px-1 flex-shrink-0">✕</button>
      </div>
      <div :if={@nodo["tipo"] in MetaPlantillas.tipos_contenedor()} id={"jal-lista-" <> @nodo["id"]} phx-hook="ListaOrdenable" data-contenedor-id={@nodo["id"]} class="min-h-[8px] mt-1">
        <.nodo_item :for={hijo <- @nodo["hijos"]} nodo={hijo} nivel={@nivel + 1} seleccionado_id={@seleccionado_id} />
      </div>
    </div>
    """
  end

  defp etiqueta_nodo(%{"tipo" => "seccion", "propiedades" => p}) do
    sufijo = if p["visible"] == false, do: " (oculta)", else: ""
    "Sección — " <> (p["titulo"] || "") <> sufijo
  end

  defp etiqueta_nodo(%{"tipo" => "campo", "propiedades" => %{"campo" => nil}}), do: "Campo — (sin elegir)"
  defp etiqueta_nodo(%{"tipo" => "campo", "propiedades" => %{"campo" => c}}), do: "Campo — #{c}"
  defp etiqueta_nodo(%{"tipo" => "campo_calculado", "propiedades" => %{"etiqueta" => e}}), do: "Campo calculado — #{e}"
  defp etiqueta_nodo(%{"tipo" => "autocompletar", "propiedades" => %{"catalogo_destino" => nil}}), do: "Autocompletar — (sin configurar)"
  defp etiqueta_nodo(%{"tipo" => "autocompletar", "propiedades" => %{"catalogo_destino" => c}}), do: "Autocompletar — #{c}"
  defp etiqueta_nodo(%{"tipo" => "divisor"}), do: "Divisor"
  defp etiqueta_nodo(%{"tipo" => "tabla", "propiedades" => %{"titulo" => t}}), do: "Tabla — #{t}"
  defp etiqueta_nodo(%{"tipo" => "etiqueta", "propiedades" => %{"texto" => t}}), do: "Etiqueta — #{t}"
  defp etiqueta_nodo(%{"tipo" => "alerta", "propiedades" => %{"nivel" => n}}), do: "Alerta (#{n})"
  defp etiqueta_nodo(%{"tipo" => "tarjeta", "propiedades" => %{"titulo" => t}}), do: "Tarjeta — #{t}"
  defp etiqueta_nodo(%{"tipo" => "fila"}), do: "Fila"
  defp etiqueta_nodo(%{"tipo" => "columna"}), do: "Columna"
  defp etiqueta_nodo(%{"tipo" => "panel"}), do: "Panel"
  defp etiqueta_nodo(%{"tipo" => "pestanas"}), do: "Pestañas"
  defp etiqueta_nodo(%{"tipo" => "pestana", "propiedades" => %{"titulo" => t}}), do: "Pestaña — #{t}"
  defp etiqueta_nodo(nodo), do: nodo["tipo"]

  # Ícono del nodo en el lienzo — para "campo" usa el tipo_filtro elegido en
  # la paleta si lo tiene (ej. muestra el ícono de calendario para un campo
  # de fecha), o el genérico si no.
  defp icono_de_nodo(%{"tipo" => "campo", "propiedades" => %{"tipo_filtro" => filtro}}) when filtro not in [nil, ""], do: filtro
  defp icono_de_nodo(nodo), do: nodo["tipo"]

  attr :nodo, :map, required: true
  attr :campos, :list, required: true
  attr :catalogos_relacionables, :list, required: true
  attr :catalogos_disponibles, :list, default: []

  defp panel_propiedades(%{nodo: %{"tipo" => "seccion"}} = assigns) do
    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Título</label>
        <input type="text" name="titulo" value={@nodo["propiedades"]["titulo"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Descripción</label>
        <textarea name="descripcion" rows="2" class="w-full border border-gray-300 rounded px-2 py-1.5">{@nodo["propiedades"]["descripcion"]}</textarea>
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Ícono (emoji, opcional)</label>
        <input type="text" name="icono" value={@nodo["propiedades"]["icono"]} maxlength="4" class="w-20 border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Espaciado</label>
        <select name="espaciado" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="compacto" selected={@nodo["propiedades"]["espaciado"] == "compacto"}>Compacto</option>
          <option value="normal" selected={(@nodo["propiedades"]["espaciado"] || "normal") == "normal"}>Normal</option>
          <option value="amplio" selected={@nodo["propiedades"]["espaciado"] == "amplio"}>Amplio</option>
        </select>
      </div>
      <label class="flex items-center gap-1.5">
        <input type="hidden" name="colapsable" value="false" />
        <input type="checkbox" name="colapsable" value="true" checked={@nodo["propiedades"]["colapsable"] == true} class="accent-purple-600" />
        Colapsable (se puede plegar/desplegar)
      </label>
      <label class="flex items-center gap-1.5">
        <input type="hidden" name="visible" value="false" />
        <input type="checkbox" name="visible" value="true" checked={@nodo["propiedades"]["visible"] != false} class="accent-purple-600" />
        Visible en la Ficha 360°
      </label>
    </form>
    """
  end

  defp panel_propiedades(%{nodo: %{"tipo" => "tarjeta"}} = assigns) do
    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Ícono (emoji, opcional)</label>
        <input type="text" name="icono" value={@nodo["propiedades"]["icono"]} maxlength="4" class="w-20 border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Título</label>
        <input type="text" name="titulo" value={@nodo["propiedades"]["titulo"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Texto</label>
        <textarea name="texto" rows="2" class="w-full border border-gray-300 rounded px-2 py-1.5">{@nodo["propiedades"]["texto"]}</textarea>
      </div>
    </form>
    """
  end

  defp panel_propiedades(%{nodo: %{"tipo" => "pestana"}} = assigns) do
    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Título de la pestaña</label>
        <input type="text" name="titulo" value={@nodo["propiedades"]["titulo"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
    </form>
    """
  end

  defp panel_propiedades(%{nodo: %{"tipo" => tipo}} = assigns) when tipo in ["fila", "columna", "panel", "pestanas"] do
    ~H"""
    <p class="text-gray-400">Sin propiedades — agregá componentes adentro desde la paleta.</p>
    """
  end

  defp panel_propiedades(%{nodo: %{"tipo" => "campo"}} = assigns) do
    filtro = assigns.nodo["propiedades"]["tipo_filtro"]
    tipos_permitidos = MetaPlantillas.tipos_de_filtro(filtro)

    campos_filtrados =
      if tipos_permitidos == [] do
        assigns.campos
      else
        Enum.filter(assigns.campos, &(&1.schema_context_properties["tipo"] in tipos_permitidos))
      end

    assigns = assign(assigns, :campos_filtrados, campos_filtrados)

    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Campo del catálogo</label>
        <select name="campo" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="" selected={is_nil(@nodo["propiedades"]["campo"])}>Elegir…</option>
          <option :for={c <- @campos_filtrados} value={c.schema_context_field} selected={@nodo["propiedades"]["campo"] == c.schema_context_field}>
            {c.schema_context_properties["etiqueta"]}
          </option>
        </select>
        <p :if={@campos_filtrados == []} class="text-gray-400 mt-1">Este catálogo no tiene campos de este tipo.</p>
      </div>
    </form>
    """
  end

  # Fórmula libre tipo Excel — evaluada por MetaPlantillas.Formula (mini
  # aritmético seguro: + - * /, paréntesis, "{campo}", "{catalogo#id.campo}",
  # SUM/COUNT/AVG/MIN/MAX(catalogo[.campo])), nunca código Elixir. La lista
  # de campos disponibles es solo una ayuda visual (los nombres reales que
  # se pueden escribir entre llaves); no valida la fórmula acá — si queda
  # mal escrita, FichaLive la muestra como "—" en vez de romper la ficha
  # (ver Formula.evaluar/2, fail-open a propósito).
  defp panel_propiedades(%{nodo: %{"tipo" => "campo_calculado"}} = assigns) do
    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Etiqueta</label>
        <input type="text" name="etiqueta" value={@nodo["propiedades"]["etiqueta"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Fórmula</label>
        <input type="text" name="formula" value={@nodo["propiedades"]["formula"]}
          placeholder="{campo_a} * {campo_b} - {campo_c}"
          class="w-full border border-gray-300 rounded px-2 py-1.5 font-mono" />
        <p class="text-gray-400 mt-1">
          Operadores: <span class="font-mono">+ - * / ( )</span>. Un campo de este registro entre llaves, ej. <span class="font-mono">{"{precio}"}</span>.
        </p>
        <p class="text-gray-400 mt-1">
          De otro catálogo (no hace falta que estén relacionados):
        </p>
        <ul class="text-gray-400 mt-0.5 list-disc list-inside">
          <li>Un registro puntual: <span class="font-mono">{"{catalogo#id.campo}"}</span></li>
          <li>Agregado sobre todos sus registros: <span class="font-mono">{"SUM(catalogo.campo)"}</span>, <span class="font-mono">COUNT(catalogo)</span>, <span class="font-mono">AVG</span>, <span class="font-mono">MIN</span>, <span class="font-mono">MAX</span></li>
        </ul>
        <p :if={@campos != []} class="text-gray-400 mt-1">
          Campos de este catálogo:
          <span :for={c <- @campos} class="font-mono bg-gray-100 rounded px-1 py-0.5 mr-1 inline-block mt-1">
            {"{" <> c.schema_context_field <> "}"}
          </span>
        </p>

        <div :if={@catalogos_disponibles != []} class="mt-2">
          <p class="text-gray-400 mb-1">Otros catálogos — click para ver sus campos:</p>
          <details :for={cat <- @catalogos_disponibles} class="mb-1 border border-gray-200 rounded">
            <summary class="cursor-pointer px-2 py-1 text-gray-600 font-semibold hover:bg-gray-50">
              <span class="font-mono">{cat.nombre}</span> — {cat.etiqueta}
            </summary>
            <div class="px-2 pb-1.5 pt-0.5">
              <span :for={c <- cat.campos} class="font-mono bg-gray-100 rounded px-1 py-0.5 mr-1 inline-block mt-1">
                {cat.nombre <> "." <> c.schema_context_field}
              </span>
              <p :if={cat.campos == []} class="text-gray-400">Este catálogo no tiene campos visibles.</p>
            </div>
          </details>
        </div>
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Decimales</label>
        <input type="number" name="decimales" min="0" max="10" value={@nodo["propiedades"]["decimales"]} class="w-24 border border-gray-300 rounded px-2 py-1.5" />
      </div>
    </form>
    """
  end

  # "Autocompletar": elegís un campo tipo referencia DE ESTE catálogo (el id
  # que el usuario tipeó ahí) y un catálogo+campos destino — en la Ficha
  # 360° se busca ESE registro puntual y se muestran sus campos de solo
  # lectura, recalculado en cada cambio (mismo mecanismo que
  # "campo_calculado", ver FichaLive.nodo_plantilla_render/1). El catálogo
  # destino NO tiene que estar relacionado a este — es la misma idea que
  # "{catalogo#id.campo}" de Formula, pero con el id dinámico en vez de
  # fijo a mano.
  defp panel_propiedades(%{nodo: %{"tipo" => "autocompletar"}} = assigns) do
    # Cualquier campo de este catálogo sirve como "campo con el id" — no
    # hace falta que esté declarado tipo "referencia" en el schema (esa
    # sería la forma prolija, pero exigirla obligaba a ir a crear un campo
    # nuevo antes de poder usar esto). buscar_relacionado/3 solo necesita
    # que el valor actual se pueda leer como entero, punto.
    catalogo_destino = assigns.nodo["propiedades"]["catalogo_destino"]
    campos_del_destino = Enum.find(assigns.catalogos_disponibles, &(&1.nombre == catalogo_destino))
    campos_destino_actuales = assigns.nodo["propiedades"]["campos_destino"] || []

    assigns =
      assigns
      |> assign(:campos_del_destino, (campos_del_destino && campos_del_destino.campos) || [])
      |> assign(:campos_destino_actuales, campos_destino_actuales)

    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Campo con el id a buscar (de este catálogo)</label>
        <select name="campo_referencia" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="" selected={is_nil(@nodo["propiedades"]["campo_referencia"])}>Elegir…</option>
          <option :for={c <- @campos} value={c.schema_context_field} selected={@nodo["propiedades"]["campo_referencia"] == c.schema_context_field}>
            {c.schema_context_properties["etiqueta"]}
          </option>
        </select>
        <p class="text-gray-400 mt-1">
          Cualquier campo cuyo valor sea un número entero funciona (no hace falta que esté marcado como "referencia").
        </p>
        <p :if={@campos == []} class="text-gray-400 mt-1">Este catálogo no tiene campos todavía.</p>
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Catálogo destino</label>
        <select name="catalogo_destino" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="" selected={is_nil(@nodo["propiedades"]["catalogo_destino"])}>Elegir…</option>
          <option :for={cat <- @catalogos_disponibles} value={cat.nombre} selected={@nodo["propiedades"]["catalogo_destino"] == cat.nombre}>
            {cat.etiqueta}
          </option>
        </select>
      </div>
      <div :if={@campos_del_destino != []}>
        <label class="block text-gray-500 mb-1">Campos a mostrar</label>
        <input type="hidden" name="campos_destino[]" value="" />
        <label :for={c <- @campos_del_destino} class="flex items-center gap-1.5 mb-1">
          <input type="checkbox" name="campos_destino[]" value={c.schema_context_field} checked={c.schema_context_field in @campos_destino_actuales} class="accent-purple-600" />
          {c.schema_context_properties["etiqueta"]}
        </label>
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Título del bloque (opcional)</label>
        <input type="text" name="titulo" value={@nodo["propiedades"]["titulo"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
    </form>
    """
  end

  defp panel_propiedades(%{nodo: %{"tipo" => "divisor"}} = assigns) do
    ~H"""
    <p class="text-gray-400">Sin propiedades.</p>
    """
  end

  defp panel_propiedades(%{nodo: %{"tipo" => "etiqueta"}} = assigns) do
    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Texto</label>
        <input type="text" name="texto" value={@nodo["propiedades"]["texto"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Estilo</label>
        <select name="estilo" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="parrafo" selected={@nodo["propiedades"]["estilo"] == "parrafo"}>Párrafo</option>
          <option value="titulo" selected={@nodo["propiedades"]["estilo"] == "titulo"}>Título</option>
        </select>
      </div>
    </form>
    """
  end

  defp panel_propiedades(%{nodo: %{"tipo" => "alerta"}} = assigns) do
    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Mensaje</label>
        <textarea name="texto" rows="2" class="w-full border border-gray-300 rounded px-2 py-1.5">{@nodo["propiedades"]["texto"]}</textarea>
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Nivel</label>
        <select name="nivel" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="info" selected={@nodo["propiedades"]["nivel"] == "info"}>Información</option>
          <option value="advertencia" selected={@nodo["propiedades"]["nivel"] == "advertencia"}>Advertencia</option>
          <option value="error" selected={@nodo["propiedades"]["nivel"] == "error"}>Error</option>
        </select>
      </div>
    </form>
    """
  end

  defp panel_propiedades(%{nodo: %{"tipo" => "tabla"}} = assigns) do
    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Catálogo relacionado</label>
        <select name="catalogo" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="" selected={is_nil(@nodo["propiedades"]["catalogo"])}>Elegir…</option>
          <option :for={{c, etiqueta} <- @catalogos_relacionables} value={c} selected={@nodo["propiedades"]["catalogo"] == c}>
            {etiqueta}
          </option>
        </select>
        <p :if={@catalogos_relacionables == []} class="text-gray-400 mt-1">Ningún catálogo referencia a éste todavía.</p>
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Título</label>
        <input type="text" name="titulo" value={@nodo["propiedades"]["titulo"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
    </form>
    """
  end

  # Disponible para CUALQUIER tipo de nodo (no solo algunos, a diferencia de
  # panel_propiedades/1) — por eso vive aparte, con su propio evento
  # ("actualizar_condicion", no "actualizar_propiedad"), y se renderiza
  # siempre debajo de las propiedades propias del tipo seleccionado.
  attr :nodo, :map, required: true
  attr :campos, :list, required: true
  attr :estados, :list, required: true

  defp panel_condicion(assigns) do
    condicion = assigns.nodo["propiedades"]["condicion"] || %{}
    assigns = assign(assigns, :condicion, condicion)

    ~H"""
    <div class="mt-4 pt-3 border-t border-gray-200">
      <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Mostrar solo si</div>
      <form phx-change="actualizar_condicion" class="flex flex-col gap-2 text-xs">
        <select name="campo" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="" selected={@condicion["campo"] in [nil, ""]}>Siempre (sin condición)</option>
          <option value="__estado__" selected={@condicion["campo"] == "__estado__"}>Estado del registro</option>
          <option :for={c <- @campos} value={c.schema_context_field} selected={@condicion["campo"] == c.schema_context_field}>
            {c.schema_context_properties["etiqueta"]}
          </option>
        </select>

        <%= if @condicion["campo"] not in [nil, ""] do %>
          <select name="operador" class="w-full border border-gray-300 rounded px-2 py-1.5">
            <option value="igual" selected={@condicion["operador"] == "igual"}>es igual a</option>
            <option value="distinto" selected={@condicion["operador"] == "distinto"}>es distinto de</option>
            <option value="vacio" selected={@condicion["operador"] == "vacio"}>está vacío</option>
            <option value="no_vacio" selected={@condicion["operador"] == "no_vacio"}>no está vacío</option>
          </select>

          <%= if @condicion["operador"] in ["igual", "distinto"] do %>
            <select :if={@condicion["campo"] == "__estado__"} name="valor" class="w-full border border-gray-300 rounded px-2 py-1.5">
              <option value="" selected={@condicion["valor"] in [nil, ""]}>Elegir estado…</option>
              <option :for={e <- @estados} value={e} selected={@condicion["valor"] == e}>{e}</option>
            </select>
            <input :if={@condicion["campo"] != "__estado__"} type="text" name="valor" value={@condicion["valor"]}
              placeholder="Valor a comparar" class="w-full border border-gray-300 rounded px-2 py-1.5" />
          <% end %>
        <% end %>
      </form>
    </div>
    """
  end

  # Ícono por tipo de componente/campo — mismo estilo (trazo fino, 24x24)
  # que ya usa el resto de la app, en vez de los caracteres Unicode que
  # tenía antes como placeholder. Cubre tanto los tipos de @tipos_estructura
  # como los filtro de @tipos_campo (no se pisan entre sí).
  attr :tipo, :string, required: true

  defp icono(%{tipo: "seccion"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="3" y="3" width="18" height="18" rx="2" /><path d="M3 9h18" />
    </svg>
    """
  end

  defp icono(%{tipo: "fila"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="3" y="4" width="7" height="16" rx="1" /><rect x="14" y="4" width="7" height="16" rx="1" />
    </svg>
    """
  end

  defp icono(%{tipo: "columna"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="7" y="3" width="10" height="18" rx="1" />
    </svg>
    """
  end

  defp icono(%{tipo: "panel"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="3" y="3" width="18" height="18" rx="2" />
    </svg>
    """
  end

  defp icono(%{tipo: "pestanas"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
    </svg>
    """
  end

  defp icono(%{tipo: "divisor"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
      <line x1="4" y1="12" x2="20" y2="12" />
    </svg>
    """
  end

  defp icono(%{tipo: "autocompletar"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="11" cy="11" r="7" /><line x1="21" y1="21" x2="16.65" y2="16.65" /><path d="M9 11h4M11 9v4" />
    </svg>
    """
  end

  defp icono(%{tipo: "campo_calculado"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M9 3H8a2 2 0 0 0-2 2v3a2 2 0 0 1-2 2 2 2 0 0 1 2 2v3a2 2 0 0 0 2 2h1" />
      <path d="M15 3h1a2 2 0 0 1 2 2v3a2 2 0 0 0 2 2 2 2 0 0 0-2 2v3a2 2 0 0 1-2 2h-1" />
      <line x1="9" y1="12" x2="15" y2="12" />
    </svg>
    """
  end

  defp icono(%{tipo: "tabla"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="3" y="3" width="18" height="18" rx="2" /><line x1="3" y1="9" x2="21" y2="9" /><line x1="3" y1="15" x2="21" y2="15" /><line x1="12" y1="3" x2="12" y2="21" />
    </svg>
    """
  end

  defp icono(%{tipo: "etiqueta"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="m20.59 13.41-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82z" /><circle cx="7" cy="7" r="1" fill="currentColor" stroke="none" />
    </svg>
    """
  end

  defp icono(%{tipo: "alerta"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0Z" /><path d="M12 9v4M12 17h.01" />
    </svg>
    """
  end

  defp icono(%{tipo: "tarjeta"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="3" y="4" width="18" height="16" rx="2" /><line x1="7" y1="4" x2="7" y2="20" />
    </svg>
    """
  end

  defp icono(%{tipo: "pestana"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
    </svg>
    """
  end

  defp icono(%{tipo: "string"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
      <line x1="4" y1="6" x2="20" y2="6" /><line x1="4" y1="12" x2="16" y2="12" /><line x1="4" y1="18" x2="12" y2="18" />
    </svg>
    """
  end

  defp icono(%{tipo: "numero"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
      <line x1="5" y1="9" x2="19" y2="9" /><line x1="5" y1="15" x2="19" y2="15" /><line x1="10" y1="4" x2="7" y2="20" /><line x1="17" y1="4" x2="14" y2="20" />
    </svg>
    """
  end

  defp icono(%{tipo: "date"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="3" y="4" width="18" height="18" rx="2" /><line x1="16" y1="2" x2="16" y2="6" /><line x1="8" y1="2" x2="8" y2="6" /><line x1="3" y1="10" x2="21" y2="10" />
    </svg>
    """
  end

  defp icono(%{tipo: "enum"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="3" y="5" width="18" height="14" rx="2" /><path d="m9 11 3 3 3-3" />
    </svg>
    """
  end

  defp icono(%{tipo: "boolean"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="4" y="4" width="16" height="16" rx="3" /><path d="m8 12 3 3 6-6" />
    </svg>
    """
  end

  defp icono(%{tipo: "referencia"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
      <path d="M9 17H7A5 5 0 0 1 7 7h2M15 7h2a5 5 0 1 1 0 10h-2M8 12h8" />
    </svg>
    """
  end

  # "campo" genérico (canvas, cuando no tiene tipo_filtro guardado — ej.
  # plantillas creadas antes de que existiera esa propiedad) + catch-all.
  defp icono(assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M12 20h9" /><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" />
    </svg>
    """
  end
end
