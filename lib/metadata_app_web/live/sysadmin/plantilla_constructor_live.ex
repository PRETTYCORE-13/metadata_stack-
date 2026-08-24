defmodule MetadataAppWeb.Sysadmin.PlantillaConstructorLive do
  @moduledoc """
  Constructor de plantillas: arma la definición que `FichaLive` usa para
  renderizar el tab "Datos" de un catálogo en vez de la lista plana de
  siempre — ver `MetadataApp.MetaPlantillas` para el modelo de datos
  ("Grid 2D" en su moduledoc) y los helpers puros que este LiveView llama.

  No hay un modo "árbol" separado del editor de grid — la raíz de la
  plantilla ES un grid desde el arranque, y siempre se está editando UNO
  (la raíz, o una Sección/Panel/Pestaña en la que se entró vía
  `entrar_contenedor/2`). El lienzo soporta arrastrar y soltar real (hook
  `GridConstructor` en assets/js/hooks/grid_constructor.js, sobre HTML5
  Drag and Drop nativo — Sortable.js no sirve acá, hace falta soltar en
  una celda (fila, columna) exacta con chequeo de ocupación).

  Los cambios (colocar/mover/combinar/editar propiedades) se hacen sobre
  `@definicion` en memoria; "Guardar" persiste, "Publicar" persiste y
  además marca esta plantilla como la única activa del catálogo.
  """


  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_bc", "editar"}}

  alias MetadataApp.Autenticacion.Scope
  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerico}
  alias MetadataApp.MetaPlantillas
  alias MetadataApp.MetaPlantillas.Formula
  alias MetadataApp.MetaStateEngine
  alias MetadataAppWeb.AdminNav

  # Paleta única — ya no hay un modo "árbol" separado del editor de grid
  # (ver moduledoc de MetaPlantillas, "Grid 2D"): TODO PostView es un solo
  # grid grande desde la raíz, así que siempre se está "adentro" de alguno
  # (la raíz misma, o una Sección/Panel/Pestaña en la que se entró — ver
  # `entrar_contenedor/2`). "fila" y "grid" NO están acá a propósito: ya no
  # hace falta insertarlos aparte, cualquier contenedor nuevo (Sección,
  # Panel, Pestaña) es un grid por dentro apenas tiene 2+ hijos. "panel"
  # sigue siendo el "contenedor interno" de la moduledoc — si una celda
  # necesita más de un componente, el ocupante de esa celda es un Panel, y
  # los demás van adentro de ESE (entrando con "Editar contenido →").
  # Agrupada por OBJETIVO ("quiero organizar", "quiero mostrar información",
  # etc.), no por tipo técnico -- a pedido explícito (2026-08-14): así
  # quien arma una plantilla piensa "quiero mostrar una relación" y va al
  # grupo Relaciones, en vez de tener que recordar de memoria si eso se
  # llama "Tabla" o "Autocompletar". "Visualización" arrancó vacía (ver
  # historial) -- ya tiene su primer miembro (Resumen/KPI); Timeline/
  # Gráfico se suman ahí cuando existan.
  @grupos_paleta [
    {"Organización", [
       {"seccion", "Sección"},
       {"panel", "Panel (varios componentes en la celda)"},
       {"pestanas", "Pestañas"},
       {"divisor", "Divisor"}
     ]},
    {"Información", [
       {"etiqueta", "Etiqueta"},
       {"tarjeta", "Tarjeta"},
       {"alerta", "Alerta"},
       {"vista_previa", "Vista previa (imagen/PDF)"}
     ]},
    {"Relaciones", [
       {"tabla", "Tabla relacionada"},
       {"autocompletar", "Datos relacionados"},
       {"lista_rapida", "Lista rápida"},
       {"renglones", "Renglones de detalle"}
     ]},
    {"Automatización", [
       {"campo_calculado", "Campo calculado"},
       {"boton", "Botón"}
     ]},
    {"Visualización", [
       {"resumen", "Resumen / KPI"},
       {"timeline", "Timeline"}
     ]}
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

  # Ruta propia (/sysadmin/bc-list/:nombre/plantilla) — sigue existiendo
  # además del tab embebido de BcMotorLive (ver clausula de abajo), por si
  # algo todavía enlaza directo para acá.
  def mount(%{"nombre" => nombre}, _session, socket) do
    montar(socket, nombre, embebido?: false)
  end

  # Embebido dentro del tab "PostView" de BcMotorLive vía live_render/3 —
  # un LiveView montado como hijo (no por el router) SIEMPRE recibe
  # `params` fijo en el átomo `:not_mounted_at_router` (nunca un mapa con
  # "nombre"), así que acá el dato viaja por `session` en vez de `params`
  # (es la única forma real de pasarle algo dinámico a un hijo — ver
  # `live_render(@socket, __MODULE__, id:, session:)` en bc_motor_live.ex).
  def mount(_params, %{"nombre" => nombre}, socket) do
    montar(socket, nombre, embebido?: true)
  end

  defp montar(socket, nombre, embebido?: embebido?) do
    socket =
      socket
      |> assign(:sidebar_open, false)
      |> assign(:current_page, "sysadmin")
      |> assign(:embebido?, embebido?)

    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        {:ok, assign(socket, :encontrado?, false)}

      header ->
        campos =
          nombre
          |> MetaSchemaContext.listar_detalles()
          |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
          # "fecha_registro" es de CONTROL (ver definicion_automatica/1 en
          # meta_plantillas.ex) — no se ofrece como "Campo" para arrastrar
          # ni como opción en los selects de referencia/condición/fórmula.
          |> Enum.reject(&(&1.schema_context_field == "fecha_registro"))

        catalogos_relacionables =
          nombre
          |> MetaSchemaContext.listar_dependientes()
          |> Enum.map(fn c -> {c, (MetaSchemaContext.obtener_header_por_nombre(c) || %{schema_context_label: c}).schema_context_label} end)

        # Para el panel de "Campo calculado" — CUALQUIER catálogo sirve para
        # SUM/COUNT/AVG/MIN/MAX o "{catalogo#id.campo}" (Formula.evaluar/2
        # no exige relación), así que acá se listan todos, no solo los
        # relacionados a este. Detalles de TODOS los catálogos en una sola
        # query (listar_detalles_de_todos_los_catalogos/0) en vez de una
        # query por catálogo — este mount corre seguido (ruta directa +
        # embebido en el tab "PostView" de BcMotorLive).
        detalles_por_catalogo = MetaSchemaContext.listar_detalles_de_todos_los_catalogos()

        catalogos_disponibles =
          MetaSchemaContext.listar_headers()
          |> Enum.reject(&(&1.schema_context_name == nombre))
          |> Enum.map(fn h ->
            campos_h =
              detalles_por_catalogo
              |> Map.get(h.schema_context_name, [])
              |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
              |> Enum.filter(&get_in(&1, [:schema_context_properties, "visible"]))

            %{nombre: h.schema_context_name, etiqueta: h.schema_context_label, campos: campos_h}
          end)

        # Catálogos detalle de ESTE maestro (Productos/Pagos/Notas, vía
        # schema_encabezado_id) — para el nodo "renglones" del panel de
        # propiedades. Distinto de catalogos_disponibles/catalogos_relacionables
        # (esos son por campo "referencia"; acá es maestro-detalle real).
        # Misma forma que cargar_catalogos_detalle/1 en FichaLive, sin
        # compartir helper entre los dos LiveViews (mismo criterio que ya usa
        # este archivo para las demás queries de mount).
        catalogos_detalle_disponibles =
          header.id
          |> MetaSchemaContext.listar_catalogos_detalle()
          |> Enum.map(fn h ->
            columnas_detalle =
              h.schema_context_name
              |> MetaSchemaContext.listar_detalles()
              |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
              |> Enum.filter(&get_in(&1, [:schema_context_properties, "visible"]))

            columnas_tabla = Enum.filter(columnas_detalle, &MetaSchemaContext.mostrar_en_tabla?(&1.schema_context_properties))

            %{nombre: h.schema_context_name, etiqueta: h.schema_context_label, columnas: columnas_detalle, columnas_tabla: columnas_tabla}
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
            # :sistema (Fase 4a) -- herramienta de Constructor, busca
            # CUALQUIER fila de muestra para previsualizar la plantilla,
            # no datos de negocio para un usuario final.
            modulo -> case CatalogoGenerico.listar(modulo, :sistema, %{}, limit: 1) do
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
         |> assign(:catalogos_detalle_disponibles, catalogos_detalle_disponibles)
         |> assign(:estados, estados)
         |> assign(:registro_muestra_id, registro_muestra_id)
         |> assign(:plantillas, plantillas)
         |> assign(:nodo_seleccionado_id, nil)
         |> assign(:grid_editando_id, nil)
         |> assign(:celda_seleccionada, nil)
         |> assign(:grid_historial_undo, [])
         |> assign(:grid_historial_redo, [])
         |> assign(:resumen_catalogo, nil)
         |> assign(:resumen_funcion, "SUM")
         |> assign(:resumen_campo, nil)
         |> assign(:lookup_catalogo, nil)
         |> assign(:lookup_id, nil)
         |> assign(:lookup_campo, nil)
         |> assign(:herramienta_calculado, nil)
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

  # Misma idea que "nueva_plantilla" de arriba, pero proposito: "impresion" —
  # FichaLive la usa en ?imprimir=1 (ver MetaPlantillas.obtener_plantilla_publicada/2)
  # en vez del selector "Vista" de pantalla.
  def handle_event("nueva_plantilla_impresion", _params, socket) do
    n = length(socket.assigns.plantillas) + 1

    attrs = %{"nombre" => "Impresión #{n}", "estado" => "borrador", "proposito" => "impresion"}

    case MetaPlantillas.crear_plantilla(socket.assigns.header.id, attrs) do
      {:ok, plantilla} ->
        plantillas = socket.assigns.plantillas ++ [plantilla]
        {:noreply, socket |> assign(:plantillas, plantillas) |> seleccionar(plantilla)}

      {:error, _changeset} ->
        {:noreply, assign(socket, :mensaje, {:error, "No se pudo crear la plantilla de impresión."})}
    end
  end

  # Para catálogos generados ANTES de que este Constructor pasara a ser un
  # grid: reconstruye el CONTENIDO de "Plantilla automática" con el
  # formato actual (ver MetaPlantillas.regenerar_plantilla_automatica/1),
  # sin tocar qué plantilla está publicada ahora mismo. Si la que se
  # estaba viendo ERA la automática, se refresca en el lugar para ver el
  # resultado de una; si no, solo se actualiza en la lista (@plantillas)
  # sin cambiar la selección actual.
  def handle_event("regenerar_automatica", _params, socket) do
    case MetaPlantillas.regenerar_plantilla_automatica(socket.assigns.header) do
      {:ok, plantilla} ->
        socket =
          socket
          |> assign(:plantillas, MetaPlantillas.listar_plantillas(socket.assigns.header.id))
          |> assign(:mensaje, {:ok, "\"Plantilla automática\" regenerada."})

        socket = if socket.assigns.plantilla && socket.assigns.plantilla.id == plantilla.id, do: seleccionar(socket, plantilla), else: socket
        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, assign(socket, :mensaje, {:error, "No se pudo regenerar la plantilla automática."})}
    end
  end

  def handle_event("seleccionar_plantilla", %{"id" => id}, socket) do
    plantilla = Enum.find(socket.assigns.plantillas, &(&1.id == String.to_integer(id)))
    {:noreply, seleccionar(socket, plantilla)}
  end

  # --- Editor de grid (hoja de cálculo) -------------------------------------
  # Ver moduledoc de MetaPlantillas ("Grid 2D") para el modelo de datos.
  # Todo lo que muta @definicion acá pasa por aplicar_cambio_grid/2, que
  # apila el estado ANTERIOR en @grid_historial_undo (deshacer/rehacer
  # acotado a esta sesión de edición de UN grid puntual — se vacía al
  # entrar/salir, ver entrar_contenedor/2).

  # Único evento de navegación entre grids — reemplaza a los viejos
  # "abrir_grid"/"cerrar_grid": entrar a una Sección/Panel/Pestaña (`id`
  # real) y volver hacia arriba por el breadcrumb (`id` vacío = raíz) son
  # el MISMO gesto (mover @grid_editando_id a otro contenedor), nunca dos
  # modos de pantalla distintos. `id` vacío llega como `""` desde
  # phx-value-id (HTML no manda `nil`), se traduce acá.
  def handle_event("entrar_contenedor", %{"id" => id}, socket) do
    {:noreply, entrar_contenedor(socket, if(id == "", do: nil, else: id))}
  end

  # "id" acá es el del contenedor "pestanas" en sí (no el de una pestaña
  # individual) — ver panel_propiedades/1 del tipo "pestanas" más abajo.
  def handle_event("agregar_pestana", %{"id" => id}, socket) do
    definicion = MetaPlantillas.agregar_pestana(socket.assigns.definicion, id)
    {:noreply, aplicar_cambio_grid(socket, definicion)}
  end

  def handle_event("eliminar_pestana", %{"id" => id}, socket) do
    definicion = MetaPlantillas.eliminar_pestana(socket.assigns.definicion, id)
    {:noreply, aplicar_cambio_grid(socket, definicion)}
  end

  # Clic en una celda VACÍA — la deja como destino para "colocar desde la
  # paleta" (grid_colocar_tipo/grid_colocar_campo) y como segundo punto de
  # "Combinar" (la primera celda es el nodo ya seleccionado, @nodo_seleccionado_id).
  def handle_event("seleccionar_celda", %{"fila" => fila, "columna" => columna}, socket) do
    {:noreply, assign(socket, :celda_seleccionada, %{fila: String.to_integer(fila), columna: String.to_integer(columna)})}
  end

  def handle_event("grid_colocar_tipo", %{"tipo" => tipo}, socket), do: colocar_en_grid(socket, nodo_de_paleta(tipo))
  def handle_event("grid_colocar_campo", %{"filtro" => filtro}, socket), do: colocar_en_grid(socket, MetaPlantillas.nuevo_nodo_campo(filtro))

  # Único destino de un "soltar" del hook GridConstructor (assets/js/hooks/grid_constructor.js)
  # — el payload trae SIEMPRE fila/columna del destino, y exactamente uno
  # de "nodo_id" (arrastró un chip ya colocado, mover_celda/4), "filtro"
  # (arrastró un botón de Campo de la paleta) o "tipo" (cualquier otro
  # botón de la paleta, @grupos_paleta).
  def handle_event("grid_soltar", %{"fila" => fila_str, "columna" => columna_str} = params, socket) do
    fila = String.to_integer(fila_str)
    columna = String.to_integer(columna_str)

    cond do
      params["nodo_id"] not in [nil, ""] ->
        case MetaPlantillas.mover_celda(socket.assigns.definicion, socket.assigns.grid_editando_id, params["nodo_id"], fila, columna) do
          {:ok, definicion} -> {:noreply, aplicar_cambio_grid(socket, definicion)}
          {:error, _} -> {:noreply, assign(socket, :mensaje, {:error, "Esa celda ya está ocupada."})}
        end

      params["filtro"] not in [nil, ""] ->
        colocar_soltado(socket, MetaPlantillas.nuevo_nodo_campo(params["filtro"]), fila, columna)

      params["tipo"] not in [nil, ""] ->
        colocar_soltado(socket, nodo_de_paleta(params["tipo"]), fila, columna)

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("grid_agregar_fila", %{"direccion" => direccion}, socket) do
    indice = fila_referencia(socket) + if(direccion == "abajo", do: 1, else: 0)
    definicion = MetaPlantillas.agregar_fila_grid(socket.assigns.definicion, socket.assigns.grid_editando_id, indice)
    {:noreply, aplicar_cambio_grid(socket, definicion)}
  end

  def handle_event("grid_agregar_columna", %{"direccion" => direccion}, socket) do
    indice = columna_referencia(socket) + if(direccion == "derecha", do: 1, else: 0)
    definicion = MetaPlantillas.agregar_columna_grid(socket.assigns.definicion, socket.assigns.grid_editando_id, indice)
    {:noreply, aplicar_cambio_grid(socket, definicion)}
  end

  def handle_event("grid_eliminar_fila", _params, socket) do
    definicion = MetaPlantillas.eliminar_fila_grid(socket.assigns.definicion, socket.assigns.grid_editando_id, fila_referencia(socket))
    {:noreply, socket |> aplicar_cambio_grid(definicion) |> assign(:celda_seleccionada, nil) |> assign(:nodo_seleccionado_id, nil)}
  end

  def handle_event("grid_eliminar_columna", _params, socket) do
    definicion = MetaPlantillas.eliminar_columna_grid(socket.assigns.definicion, socket.assigns.grid_editando_id, columna_referencia(socket))
    {:noreply, socket |> aplicar_cambio_grid(definicion) |> assign(:celda_seleccionada, nil) |> assign(:nodo_seleccionado_id, nil)}
  end

  def handle_event("grid_duplicar_fila", _params, socket) do
    definicion = MetaPlantillas.duplicar_fila_grid(socket.assigns.definicion, socket.assigns.grid_editando_id, fila_referencia(socket))
    {:noreply, aplicar_cambio_grid(socket, definicion)}
  end

  # Suma como filas nuevas, al final de ESTE grid, los campos del catálogo
  # que todavía no estén en ningún lado de la plantilla — nunca reemplaza
  # nada de lo que ya había (a diferencia de "regenerar_automatica", que
  # sí pisa el contenido entero). Útil después de agregar un campo nuevo
  # en Configuración sobre una Vista Post que ya se armó/personalizó a mano.
  def handle_event("agregar_campos_faltantes", _params, socket) do
    {definicion, cantidad} = MetaPlantillas.agregar_campos_faltantes(socket.assigns.definicion, socket.assigns.header, socket.assigns.grid_editando_id)

    if cantidad > 0 do
      {:noreply, aplicar_cambio_grid(socket, definicion)}
    else
      {:noreply, assign(socket, :mensaje, {:ok, "No hay campos nuevos para agregar acá."})}
    end
  end

  # Ancla = nodo ya seleccionado (@nodo_seleccionado_id); destino = celda
  # elegida después con un clic (@celda_seleccionada) — mismo gesto de
  # "elegí origen, después destino" que ya usa el resto del panel.
  def handle_event("grid_combinar", _params, socket) do
    with id when not is_nil(id) <- socket.assigns.nodo_seleccionado_id,
         %{fila: fila_fin, columna: columna_fin} <- socket.assigns.celda_seleccionada,
         {:ok, definicion} <- MetaPlantillas.combinar_celdas(socket.assigns.definicion, socket.assigns.grid_editando_id, id, fila_fin, columna_fin) do
      {:noreply, socket |> aplicar_cambio_grid(definicion) |> assign(:celda_seleccionada, nil)}
    else
      _ -> {:noreply, assign(socket, :mensaje, {:error, "Elegí un componente y después una celda destino para combinar."})}
    end
  end

  def handle_event("grid_separar", _params, socket) do
    case socket.assigns.nodo_seleccionado_id do
      nil -> {:noreply, socket}
      id -> {:noreply, aplicar_cambio_grid(socket, MetaPlantillas.separar_celda(socket.assigns.definicion, id))}
    end
  end

  # "Limpiar celda": saca el componente de la celda (quitar_componente/2,
  # ya existente) SIN tocar filas/columnas — a diferencia de "Eliminar
  # fila/columna" de arriba.
  def handle_event("grid_limpiar_celda", _params, socket) do
    case socket.assigns.nodo_seleccionado_id do
      nil ->
        {:noreply, socket}

      id ->
        definicion = MetaPlantillas.quitar_componente(socket.assigns.definicion, id)
        {:noreply, socket |> aplicar_cambio_grid(definicion) |> assign(:nodo_seleccionado_id, nil)}
    end
  end

  def handle_event("grid_deshacer", _params, socket) do
    case socket.assigns.grid_historial_undo do
      [anterior | resto] ->
        {:noreply,
         socket
         |> assign(:grid_historial_redo, [socket.assigns.definicion | socket.assigns.grid_historial_redo])
         |> assign(:grid_historial_undo, resto)
         |> assign(:definicion, anterior)}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_event("grid_rehacer", _params, socket) do
    case socket.assigns.grid_historial_redo do
      [siguiente | resto] ->
        {:noreply,
         socket
         |> assign(:grid_historial_undo, [socket.assigns.definicion | socket.assigns.grid_historial_undo])
         |> assign(:grid_historial_redo, resto)
         |> assign(:definicion, siguiente)}

      [] ->
        {:noreply, socket}
    end
  end

  # Form del panel "Celda" (panel_celda/1) — pisa propiedades["celda"] del
  # nodo seleccionado. La geometría (fila/columna/colspan/rowspan) se
  # revalida contra celda_libre?/6 acá mismo: si el rectángulo pedido
  # choca con otro componente, esos 4 campos se ignoran en silencio (el
  # resto del form — alineación, padding, estilo, responsive — sí se
  # aplica igual) en vez de tirar el cambio entero.
  def handle_event("actualizar_celda", params, socket) do
    id = socket.assigns.nodo_seleccionado_id
    cambios = celda_cambios_desde_params(params, socket.assigns.definicion, socket.assigns.grid_editando_id, id)
    {:noreply, aplicar_cambio_grid(socket, MetaPlantillas.actualizar_celda(socket.assigns.definicion, id, cambios))}
  end

  # El selector de "Resumen" (catálogo/función/campo) es estado transitorio
  # del panel, no de la definicion — se resetea cada vez que cambia el
  # nodo seleccionado para no arrastrar una elección de un campo_calculado
  # a otro sin querer. Seleccionar un chip es siempre el ancla de un gesto
  # nuevo ("Combinar" mira nodo_seleccionado_id como ancla + la celda que
  # se clickee DESPUÉS como destino, ver grid_combinar) — por eso también
  # limpia celda_seleccionada: una celda vacía elegida en un momento suelto
  # de ANTES (ej. solo explorando) no puede quedar pegada como destino de
  # un "Combinar" que el usuario nunca pidió.
  def handle_event("seleccionar_nodo", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:nodo_seleccionado_id, id)
     |> assign(:celda_seleccionada, nil)
     |> reset_resumen()
     |> reset_lookup()
     |> assign(:herramienta_calculado, nil)}
  end

  # Checkboxes de panel_propiedades/1 (hidden+checkbox "false"/"true", mismo
  # patrón HTML en todos los tipos) -- sin esto, un checkbox tildado guarda
  # literalmente el STRING "true" en vez del booleano `true`, y
  # FichaLive.nodo_plantilla_render/1 hace pattern match contra el
  # booleano (ej. %{"colapsable" => true}) -- nunca matchea un string,
  # así que la sección quedaba silenciosamente NO colapsable pase lo que
  # pase en el checkbox. Bug real, encontrado al agregar "confirmar_antes"
  # de Botón (mismo patrón nuevo). panel_celda/1 (evento "actualizar_celda",
  # celda_cambios_desde_params/4) ya hacía esta conversión bien -- acá era
  # el único lugar que le faltaba.
  @propiedades_booleanas ~w(colapsable visible confirmar_antes iniciar_expandida recordar_estado contador_campos mostrar_total)

  def handle_event("actualizar_propiedad", params, socket) do
    id = socket.assigns.nodo_seleccionado_id

    propiedades =
      params
      |> Map.drop(["_target"])
      |> Map.new(fn
        {campo, valor} when campo in @propiedades_booleanas -> {campo, valor == "true"}
        par -> par
      end)

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

  # --- Constructor de chips de "Fórmula" (campo_calculado) -----------------
  # La fórmula sigue siendo el mismo string de siempre (Formula.evaluar/2 no
  # cambió nada) — estos 4 eventos solo la arman/editan por clicks en vez de
  # tipeándola: agregar_token_formula/2 concatena texto al final, y
  # "formula_quitar_token" re-tokeniza con el MISMO tokenizer del evaluador
  # (Formula.tokens_para_mostrar/1) y vuelve a armar el string sin ese token
  # — nunca hay dos fuentes de verdad de qué es "un token".
  def handle_event("formula_agregar_campo", %{"campo" => campo}, socket) do
    agregar_token_formula(socket, "{#{campo}}")
  end

  def handle_event("formula_agregar_operador", %{"op" => op}, socket) do
    agregar_token_formula(socket, op)
  end

  # El input de número vive suelto (sin <form>, para no anidar otro form
  # adentro del "actualizar_propiedad" que ya envuelve todo el panel) —
  # dispara por phx-keyup en vez de un submit, así que el payload trae
  # "value" (lo que ya tipeó), no "valor".
  def handle_event("formula_agregar_numero", %{"value" => valor}, socket) when valor not in [nil, ""] do
    agregar_token_formula(socket, valor)
  end

  def handle_event("formula_agregar_numero", _params, socket), do: {:noreply, socket}

  # Mismo criterio que el número: input suelto, dispara por Enter. Se le
  # sacan las comillas que el usuario haya tipeado (si escribe una queda
  # mal balanceado el token) antes de envolverlo — el chip siempre se
  # arma con comillas rectas, nunca lo que haya tipeado la persona.
  def handle_event("formula_agregar_texto", %{"value" => valor}, socket) when valor not in [nil, ""] do
    texto = String.replace(valor, "\"", "")
    agregar_token_formula(socket, "\"#{texto}\"")
  end

  def handle_event("formula_agregar_texto", _params, socket), do: {:noreply, socket}

  def handle_event("formula_quitar_token", %{"indice" => indice}, socket) do
    id = socket.assigns.nodo_seleccionado_id
    nodo = MetaPlantillas.buscar_nodo(socket.assigns.definicion, id)
    tokens = Formula.tokens_para_mostrar(nodo["propiedades"]["formula"] || "")
    nueva_formula = tokens |> List.delete_at(String.to_integer(indice)) |> Enum.map_join(" ", &texto_de_token/1)
    definicion = MetaPlantillas.actualizar_propiedades(socket.assigns.definicion, id, %{"formula" => nueva_formula})

    {:noreply, assign(socket, :definicion, definicion)}
  end

  def handle_event("formula_vaciar", _params, socket) do
    id = socket.assigns.nodo_seleccionado_id
    definicion = MetaPlantillas.actualizar_propiedades(socket.assigns.definicion, id, %{"formula" => ""})

    {:noreply, assign(socket, :definicion, definicion)}
  end

  # "Editar como texto" del panel Avanzado — vive fuera del <form> de
  # Etiqueta/Decimales (evita anidar dos <form>), así que es un input
  # suelto con su propio phx-change en vez de depender de
  # "actualizar_propiedad".
  def handle_event("formula_set_texto", %{"value" => valor}, socket) do
    id = socket.assigns.nodo_seleccionado_id
    definicion = MetaPlantillas.actualizar_propiedades(socket.assigns.definicion, id, %{"formula" => valor})

    {:noreply, assign(socket, :definicion, definicion)}
  end

  # --- Selector de "Resumen" (SUM/COUNT/AVG/MIN/MAX sobre otro catálogo) ---
  # Los 3 <select> son independientes (no un <form>, mismo motivo que
  # arriba) — cada uno guarda su elección como estado transitorio del
  # panel; "Agregar a la fórmula" recién ahí arma el token real.
  def handle_event("resumen_set_funcion", %{"funcion" => funcion}, socket) do
    {:noreply, assign(socket, :resumen_funcion, funcion)}
  end

  def handle_event("resumen_set_catalogo", %{"catalogo" => catalogo}, socket) do
    {:noreply, socket |> assign(:resumen_catalogo, catalogo) |> assign(:resumen_campo, nil)}
  end

  def handle_event("resumen_set_campo", %{"campo" => campo}, socket) do
    {:noreply, assign(socket, :resumen_campo, campo)}
  end

  def handle_event("formula_agregar_agregado", _params, %{assigns: %{resumen_catalogo: catalogo}} = socket) when catalogo in [nil, ""] do
    {:noreply, socket}
  end

  def handle_event("formula_agregar_agregado", _params, %{assigns: %{resumen_funcion: "COUNT"}} = socket) do
    agregar_token_formula(socket, "COUNT(#{socket.assigns.resumen_catalogo})")
  end

  def handle_event("formula_agregar_agregado", _params, %{assigns: %{resumen_campo: campo}} = socket) when campo in [nil, ""] do
    {:noreply, socket}
  end

  def handle_event("formula_agregar_agregado", _params, socket) do
    %{resumen_funcion: funcion, resumen_catalogo: catalogo, resumen_campo: campo} = socket.assigns
    agregar_token_formula(socket, "#{funcion}(#{catalogo}.#{campo})")
  end

  # "¿Qué querés agregar?" — tarjetas grandes que muestran/ocultan UN
  # constructor secundario a la vez (Resumen / Condición / Otro registro),
  # en vez de los 3 apilados y siempre visibles — el ruido visual real
  # venía de mostrar todo junto, no de que faltara alguno. La tira de
  # chips + campos/contexto/operadores de arriba (la fórmula en sí) sigue
  # siempre visible: no es "un tipo" más, es lo que se está armando.
  # Tocar la misma tarjeta ya activa la cierra (toggle).
  def handle_event("seleccionar_herramienta_calculado", %{"herramienta" => herramienta}, socket) do
    nueva = if socket.assigns.herramienta_calculado == herramienta, do: nil, else: herramienta
    {:noreply, assign(socket, :herramienta_calculado, nueva)}
  end

  # --- Selector de "Lookup fijo" (registro puntual de otro catálogo) -------
  # Mismo patrón que "Resumen" de arriba — 3 controles sueltos, estado
  # transitorio del panel, y recién "Agregar a la fórmula" arma el token
  # real "{catalogo#id.campo}" (mismo formato que Formula.evaluar/2 ya
  # reconoce por su cuenta — acá solo se lo arma por clicks en vez de a
  # mano en "Avanzado").
  def handle_event("lookup_set_catalogo", %{"catalogo" => catalogo}, socket) do
    {:noreply, socket |> assign(:lookup_catalogo, catalogo) |> assign(:lookup_campo, nil)}
  end

  def handle_event("lookup_set_id", %{"registro_id" => id}, socket) do
    {:noreply, assign(socket, :lookup_id, id)}
  end

  def handle_event("lookup_set_campo", %{"campo" => campo}, socket) do
    {:noreply, assign(socket, :lookup_campo, campo)}
  end

  def handle_event("formula_agregar_lookup", _params, %{assigns: %{lookup_catalogo: catalogo}} = socket)
      when catalogo in [nil, ""] do
    {:noreply, socket}
  end

  def handle_event("formula_agregar_lookup", _params, %{assigns: %{lookup_campo: campo}} = socket)
      when campo in [nil, ""] do
    {:noreply, socket}
  end

  def handle_event("formula_agregar_lookup", _params, %{assigns: %{lookup_id: id}} = socket) do
    if id_valido?(id) do
      %{lookup_catalogo: catalogo, lookup_campo: campo} = socket.assigns
      agregar_token_formula(socket, "{#{catalogo}##{id}.#{campo}}")
    else
      {:noreply, socket}
    end
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
          # "/nuevo" (alta) en vez de un registro real puntual — así se
          # puede previsualizar el DISEÑO (layout, agrupación, campos)
          # desde el primer momento, sin depender de que el catálogo ya
          # tenga algún registro cargado (antes la vista previa ni
          # aparecía si @registro_muestra_id era nil). Los valores se ven
          # en blanco (@registro = %{} en modo :alta), pero eso no importa
          # para juzgar el layout — es justamente lo que se está diseñando acá.
          url = "/registro/#{socket.assigns.nombre}/nuevo?plantilla_id=#{plantilla.id}"

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

  # "Disponible como vista" — independiente de publicar/despublicar (ver
  # MetaPlantillas.listar_disponibles_multi_vista/1): habilita/deshabilita
  # que FichaLive la ofrezca en su selector "Vista" a usuarios finales.
  def handle_event("alternar_disponible_multi_vista", _params, socket) do
    case MetaPlantillas.alternar_disponible_multi_vista(socket.assigns.plantilla) do
      {:ok, plantilla} ->
        {:noreply, socket |> assign(:plantilla, plantilla) |> actualizar_en_lista(plantilla)}

      {:error, _changeset} ->
        {:noreply, assign(socket, :mensaje, {:error, "No se pudo cambiar la disponibilidad."})}
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

  defp agregar_token_formula(socket, texto_nuevo) do
    id = socket.assigns.nodo_seleccionado_id
    nodo = MetaPlantillas.buscar_nodo(socket.assigns.definicion, id)
    formula_actual = nodo["propiedades"]["formula"] || ""
    nueva_formula = String.trim(formula_actual <> " " <> texto_nuevo)
    definicion = MetaPlantillas.actualizar_propiedades(socket.assigns.definicion, id, %{"formula" => nueva_formula})

    {:noreply, assign(socket, :definicion, definicion)}
  end

  defp reset_resumen(socket) do
    socket |> assign(:resumen_catalogo, nil) |> assign(:resumen_funcion, "SUM") |> assign(:resumen_campo, nil)
  end

  defp reset_lookup(socket) do
    socket |> assign(:lookup_catalogo, nil) |> assign(:lookup_id, nil) |> assign(:lookup_campo, nil)
  end

  # Mismo patrón que reconoce Formula ("#(\d+)\." en el regex del lookup) —
  # se valida acá también para no armar un token roto tipo "{cat#.campo}"
  # con solo darle clic al botón sin completar el id.
  defp id_valido?(id), do: is_binary(id) and Regex.match?(~r/^\d+$/, id)

  defp seleccionar(socket, nil) do
    socket
    |> assign(:plantilla, nil)
    |> assign(:definicion, nil)
    |> assign(:nodo_seleccionado_id, nil)
    |> assign(:grid_editando_id, nil)
    |> assign(:celda_seleccionada, nil)
    |> assign(:grid_historial_undo, [])
    |> assign(:grid_historial_redo, [])
  end

  defp seleccionar(socket, plantilla) do
    socket
    |> assign(:plantilla, plantilla)
    |> assign(:definicion, plantilla.definicion)
    |> assign(:nodo_seleccionado_id, nil)
    |> assign(:grid_editando_id, nil)
    |> assign(:celda_seleccionada, nil)
    |> assign(:grid_historial_undo, [])
    |> assign(:grid_historial_redo, [])
  end

  # --- Helpers privados del editor de grid ----------------------------------

  # "pestanas" necesita nacer con 2 pestañas ya adentro (nuevo_nodo_pestanas/0)
  # — el resto de la paleta (@grupos_paleta) es un nuevo_nodo/1 genérico.
  defp nodo_de_paleta("pestanas"), do: MetaPlantillas.nuevo_nodo_pestanas()
  defp nodo_de_paleta(tipo), do: MetaPlantillas.nuevo_nodo(tipo)

  defp entrar_contenedor(socket, id) do
    socket
    |> assign(:grid_editando_id, id)
    |> assign(:celda_seleccionada, nil)
    |> assign(:nodo_seleccionado_id, nil)
    |> assign(:grid_historial_undo, [])
    |> assign(:grid_historial_redo, [])
  end

  # Único punto de mutación del editor de grid — SIEMPRE apila el
  # @definicion ANTERIOR en el undo y vacía el redo, así ningún
  # handle_event de arriba tiene que acordarse de hacerlo a mano.
  defp aplicar_cambio_grid(socket, nueva_definicion) do
    socket
    |> assign(:grid_historial_undo, [socket.assigns.definicion | Enum.take(socket.assigns.grid_historial_undo, 29)])
    |> assign(:grid_historial_redo, [])
    |> assign(:definicion, nueva_definicion)
  end

  defp colocar_en_grid(socket, nodo) do
    case socket.assigns.celda_seleccionada do
      nil -> {:noreply, assign(socket, :mensaje, {:error, "Elegí primero una celda vacía del grid."})}
      %{fila: fila, columna: columna} -> colocar_soltado(socket, nodo, fila, columna)
    end
  end

  defp colocar_soltado(socket, nodo, fila, columna) do
    case MetaPlantillas.colocar_en_celda(socket.assigns.definicion, socket.assigns.grid_editando_id, nodo, fila, columna) do
      {:ok, definicion} ->
        {:noreply, socket |> aplicar_cambio_grid(definicion) |> assign(:nodo_seleccionado_id, nodo["id"]) |> assign(:celda_seleccionada, nil)}

      {:error, _} ->
        {:noreply, assign(socket, :mensaje, {:error, "Esa celda ya está ocupada."})}
    end
  end

  # Fila/columna "de referencia" para Agregar/Eliminar/Duplicar fila o
  # columna: la celda vacía elegida por clic si hay una; si no, la del
  # componente seleccionado (siempre que sea hijo del grid que se está
  # editando); si tampoco, la primera (0).
  defp fila_referencia(socket), do: celda_referencia(socket)["fila"]
  defp columna_referencia(socket), do: celda_referencia(socket)["columna"]

  defp celda_referencia(socket) do
    case socket.assigns.celda_seleccionada do
      %{fila: fila, columna: columna} ->
        %{"fila" => fila, "columna" => columna}

      nil ->
        case nodo_en_grid_seleccionado(socket) do
          nil -> %{"fila" => 0, "columna" => 0}
          nodo -> Map.merge(MetaPlantillas.celda_default(), nodo["propiedades"]["celda"] || %{})
        end
    end
  end

  defp nodo_en_grid_seleccionado(socket) do
    case socket.assigns.nodo_seleccionado_id do
      nil -> nil
      id -> MetaPlantillas.buscar_nodo(socket.assigns.definicion, id)
    end
  end

  # Arma el mapa de cambios para "actualizar_celda" — geometría
  # (fila/columna/colspan/rowspan) revalidada contra celda_libre?/6 antes
  # de aplicarse (si no cabe, se descarta EN SILENCIO, el resto del form
  # sigue aplicándose); estilo/responsive siempre son sub-mapas completos
  # (nunca un merge parcial a medias, para no dejar basura de una versión
  # vieja del formulario).
  defp celda_cambios_desde_params(params, definicion, grid_id, id) do
    nodo = MetaPlantillas.buscar_nodo(definicion, id)
    celda_actual = Map.merge(MetaPlantillas.celda_default(), (nodo && nodo["propiedades"]["celda"]) || %{})
    grid_nodo = MetaPlantillas.grid_host(definicion, grid_id)

    fila = entero(params["fila"], celda_actual["fila"])
    columna = entero(params["columna"], celda_actual["columna"])
    colspan = max(entero(params["colspan"], celda_actual["colspan"]), 1)
    rowspan = max(entero(params["rowspan"], celda_actual["rowspan"]), 1)

    geometria =
      if grid_nodo && MetaPlantillas.celda_libre?(grid_nodo, fila, columna, colspan, rowspan, id) do
        %{"fila" => fila, "columna" => columna, "colspan" => colspan, "rowspan" => rowspan}
      else
        %{}
      end

    %{
      "ancho" => blank_to_nil(params["ancho"]),
      "alto" => blank_to_nil(params["alto"]),
      "alineacion_h" => params["alineacion_h"] || celda_actual["alineacion_h"],
      "alineacion_v" => params["alineacion_v"] || celda_actual["alineacion_v"],
      "padding" => params["padding"] || celda_actual["padding"],
      "visible" => params["visible"] == "true",
      "estilo" => %{
        "fondo" => params["estilo_fondo"] || "",
        "borde" => params["estilo_borde"] == "true",
        "redondeado" => params["estilo_redondeado"] == "true",
        "sombra" => params["estilo_sombra"] == "true",
        "color_texto" => params["estilo_color_texto"] || ""
      },
      "responsive" => %{
        "ocultar_movil" => params["responsive_ocultar_movil"] == "true",
        "colspan_movil" => entero_opcional(params["responsive_colspan_movil"]),
        "rowspan_movil" => entero_opcional(params["responsive_rowspan_movil"]),
        "orden_movil" => entero_opcional(params["responsive_orden_movil"])
      }
    }
    |> Map.merge(geometria)
  end

  defp entero(valor, default) do
    case Integer.parse(to_string(valor || "")) do
      {n, _} -> n
      :error -> default
    end
  end

  defp entero_opcional(valor) do
    case Integer.parse(to_string(valor || "")) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

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
    assigns = assigns |> assign(:grupos_paleta, @grupos_paleta) |> assign(:tipos_campo, @tipos_campo)

    ~H"""
    <div class={if @embebido?, do: "", else: "p-6"}>
      <div class="flex items-center justify-between flex-wrap gap-2 mb-4">
        <div :if={!@embebido?}>
          <h1 class="text-xl font-bold text-gray-900">PostView — {@header.schema_context_label}</h1>
          <p class="text-xs text-gray-500 mt-0.5">Diseña el tab "Datos" de la Ficha 360° de este catálogo.</p>
        </div>
        <div :if={@embebido?}></div>
        <div class="flex items-center gap-2 flex-wrap">
          <form :if={@plantillas != []} phx-change="seleccionar_plantilla">
            <select id={"plantilla-selector-#{@plantilla && @plantilla.id}"} name="id"
              class="border border-gray-300 rounded-lg text-sm px-2 py-1.5 text-gray-700">
              <optgroup label="Vistas">
                <option :for={p <- Enum.filter(@plantillas, &(&1.proposito == "vista"))} value={p.id} selected={@plantilla && @plantilla.id == p.id}>
                  {etiqueta_opcion_plantilla(p)}
                </option>
              </optgroup>
              <optgroup :if={Enum.any?(@plantillas, &(&1.proposito == "impresion"))} label="Impresión">
                <option :for={p <- Enum.filter(@plantillas, &(&1.proposito == "impresion"))} value={p.id} selected={@plantilla && @plantilla.id == p.id}>
                  {p.nombre} · {p.estado}
                </option>
              </optgroup>
            </select>
          </form>
          <span :if={@plantilla} class={[
            "text-[11px] font-semibold px-2 py-1 rounded-full whitespace-nowrap",
            @plantilla.estado == "publicada" && "bg-green-50 text-green-700",
            @plantilla.estado != "publicada" && "bg-gray-100 text-gray-500"
          ]}>
            {if @plantilla.estado == "publicada", do: "● Publicada", else: "○ Borrador"}
          </span>
          <label :if={@plantilla} class="flex items-center gap-1.5 text-[11px] text-gray-600 whitespace-nowrap cursor-pointer select-none"
            title="Los usuarios podrán elegir este PostView desde el selector Vista al ver un registro de este catálogo.">
            <input type="checkbox" phx-click="alternar_disponible_multi_vista" checked={@plantilla.disponible_multi_vista}
              class="rounded border-gray-300 text-purple-600 focus:ring-purple-500" />
            Disponible como vista
          </label>
          <div class="w-px h-5 bg-gray-200 mx-1"></div>
          <button type="button" phx-click="nueva_plantilla" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 text-xs font-semibold hover:bg-gray-50">
            + Nuevo PostView
          </button>
          <button type="button" phx-click="nueva_plantilla_impresion"
            title="Diseña qué se ve al imprimir/guardar como PDF un registro de este catálogo (botón Imprimir de la Ficha 360°)."
            class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 text-xs font-semibold hover:bg-gray-50">
            + Nueva plantilla de impresión
          </button>
          <button type="button" phx-click="regenerar_automatica"
            title={"Reconstruye 'Plantilla automática' (todos los campos, 1 columna × N filas) con el formato actual — para catálogos generados antes de que esto fuera un grid. No cambia qué plantilla está publicada."}
            class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 text-xs font-semibold hover:bg-gray-50">
            ↻ Regenerar automática
          </button>
          <button :if={@plantilla} type="button" phx-click="vista_previa" phx-hook="AbrirVistaPrevia" id="btn-vista-previa"
            title="Abre la Ficha de un registro nuevo (en blanco) con este diseño — no hace falta tener ningún registro cargado todavía"
            class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 text-xs font-semibold hover:bg-gray-50">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8Z" /><circle cx="12" cy="12" r="3" /></svg>
            Vista previa
          </button>
          <button :if={@plantilla} type="button" phx-click="guardar" class="px-3 py-1.5 rounded-lg border border-purple-300 text-purple-700 text-xs font-semibold hover:bg-purple-50">
            Guardar
          </button>
          <%!-- Mismo botón/acción de siempre (phx-click="publicar") — solo cambia
               el texto cuando ya está publicada, para que no diga "Publicar"
               sobre algo que ya lo está. Mismo criterio de texto que ya usa el
               selector de arriba para el propósito "vista"
               (etiqueta_opcion_plantilla/1). --%>
          <button :if={@plantilla} type="button" phx-click="publicar"
            title={@plantilla.estado == "publicada" && (if @plantilla.proposito == "vista", do: "Ya es la vista que ven todos los usuarios por defecto — publicar de nuevo no cambia nada", else: "Ya es la plantilla que se usa al imprimir — publicar de nuevo no cambia nada")}
            class="px-3 py-1.5 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700">
            {if @plantilla.estado == "publicada", do: (if @plantilla.proposito == "vista", do: "Vista default", else: "Impresión activa"), else: "Publicar"}
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

      <div :if={@plantilla} class="grid grid-cols-1 lg:grid-cols-[180px_1fr_280px] gap-4">
        <div class="bg-white border border-gray-200 rounded-xl p-3">
          <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Componentes</div>
          <div :for={{grupo, items} <- @grupos_paleta} class="mb-3">
            <div class="text-[10px] font-semibold text-gray-400 mb-1">{grupo}</div>
            <div class="flex flex-col gap-1.5">
              <button :for={{tipo, etiqueta} <- items} type="button" draggable="true" data-origen="paleta" data-tipo={tipo}
                phx-click="grid_colocar_tipo" phx-value-tipo={tipo}
                class="gc-paleta-item flex items-center gap-2.5 text-left px-2 py-1.5 rounded-lg border border-transparent text-xs font-semibold text-gray-600 hover:border-gray-200 hover:bg-gray-50 cursor-grab">
                <span class="gc-paleta-icono"><.icono tipo={tipo} /></span> {etiqueta}
              </button>
            </div>
          </div>
          <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Campos</div>
          <div class="flex flex-col gap-1.5">
            <button :for={{filtro, etiqueta} <- @tipos_campo} type="button" draggable="true" data-origen="paleta" data-filtro={filtro}
              phx-click="grid_colocar_campo" phx-value-filtro={filtro}
              class="gc-paleta-item flex items-center gap-2.5 text-left px-2 py-1.5 rounded-lg border border-transparent text-xs font-semibold text-gray-600 hover:border-gray-200 hover:bg-gray-50 cursor-grab">
              <span class="gc-paleta-icono"><.icono tipo={filtro} /></span> {etiqueta}
            </button>
          </div>
          <p class="text-[11px] text-gray-400 mt-3">
            Arrastrá un componente a una celda, o hacé clic en una celda vacía y después acá.
          </p>
        </div>

        <div class="bg-white border border-gray-200 rounded-xl p-4 min-h-[300px]">
          <.grid_editor grid={MetaPlantillas.grid_host(@definicion, @grid_editando_id)} ruta={MetaPlantillas.ruta_hasta(@definicion, @grid_editando_id)}
            nodo_seleccionado_id={@nodo_seleccionado_id} celda_seleccionada={@celda_seleccionada}
            puede_deshacer={@grid_historial_undo != []} puede_rehacer={@grid_historial_redo != []}
            campos={@campos} catalogos_disponibles={@catalogos_disponibles} catalogos_detalle_disponibles={@catalogos_detalle_disponibles} />
        </div>

        <div class="bg-white border border-gray-200 rounded-xl p-3">
          <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Propiedades</div>
          <.panel_celda :if={@nodo_seleccionado_id} nodo={MetaPlantillas.buscar_nodo(@definicion, @nodo_seleccionado_id)} />
          <.panel_propiedades :if={@nodo_seleccionado_id} nodo={MetaPlantillas.buscar_nodo(@definicion, @nodo_seleccionado_id)} campos={@campos} catalogos_relacionables={@catalogos_relacionables} catalogos_disponibles={@catalogos_disponibles}
            catalogos_detalle_disponibles={@catalogos_detalle_disponibles}
            resumen_catalogo={@resumen_catalogo} resumen_funcion={@resumen_funcion} resumen_campo={@resumen_campo}
            lookup_catalogo={@lookup_catalogo} lookup_id={@lookup_id} lookup_campo={@lookup_campo} definicion={@definicion}
            herramienta_calculado={@herramienta_calculado}
            nombre={@nombre} registro_muestra_id={@registro_muestra_id} current_scope={@current_scope} />
          <p :if={!@nodo_seleccionado_id} class="text-xs text-gray-400">Elegí una celda ocupada del grid.</p>
          <.panel_condicion :if={@nodo_seleccionado_id} nodo={MetaPlantillas.buscar_nodo(@definicion, @nodo_seleccionado_id)} campos={@campos} estados={@estados} />
        </div>
      </div>
    </div>
    """
  end

  # La plantilla "vista" publicada es la que ve cualquier usuario final sin
  # elegir nada (mismo criterio que ya usa el selector "Vista" de FichaLive,
  # que a esa la llama literalmente "Vista: Predeterminada") — acá mostrar
  # su nombre técnico ("Plantilla automática", etc.) confundía sobre cuál
  # es la que de verdad está activa para todos.
  defp etiqueta_opcion_plantilla(%{estado: "publicada"} = p), do: "Vista predeterminada" <> (p.disponible_multi_vista && " · disponible" || "")
  defp etiqueta_opcion_plantilla(p), do: "#{p.nombre} · #{p.estado}" <> (p.disponible_multi_vista && " · disponible" || "")

  defp etiqueta_nodo(%{"tipo" => "seccion", "propiedades" => p}) do
    sufijo = if p["visible"] == false, do: " (oculta)", else: ""
    "Sección — " <> (p["titulo"] || "") <> sufijo
  end

  defp etiqueta_nodo(%{"tipo" => "campo", "propiedades" => %{"campo" => nil}}), do: "Campo — (sin elegir)"
  defp etiqueta_nodo(%{"tipo" => "campo", "propiedades" => %{"campo" => c}}), do: "Campo — #{c}"
  defp etiqueta_nodo(%{"tipo" => "campo_calculado", "propiedades" => %{"etiqueta" => e}}), do: "Campo calculado — #{e}"
  defp etiqueta_nodo(%{"tipo" => "autocompletar", "propiedades" => %{"catalogo_destino" => nil}}), do: "Datos relacionados — (sin configurar)"
  defp etiqueta_nodo(%{"tipo" => "autocompletar", "propiedades" => %{"catalogo_destino" => c}}), do: "Datos relacionados — #{c}"
  defp etiqueta_nodo(%{"tipo" => "divisor", "propiedades" => %{"titulo" => titulo}}) when titulo not in [nil, ""], do: "Divisor — #{titulo}"
  defp etiqueta_nodo(%{"tipo" => "divisor"}), do: "Divisor"
  defp etiqueta_nodo(%{"tipo" => "tabla", "propiedades" => %{"titulo" => t}}), do: "Tabla — #{t}"
  defp etiqueta_nodo(%{"tipo" => "lista_rapida", "propiedades" => %{"catalogo" => nil}}), do: "Lista rápida — (sin configurar)"
  defp etiqueta_nodo(%{"tipo" => "lista_rapida", "propiedades" => %{"catalogo" => c}}), do: "Lista rápida — #{c}"
  defp etiqueta_nodo(%{"tipo" => "renglones", "propiedades" => %{"catalogo" => nil}}), do: "Renglones de detalle — (sin configurar)"
  defp etiqueta_nodo(%{"tipo" => "renglones", "propiedades" => %{"catalogo" => c}}), do: "Renglones de detalle — #{c}"
  defp etiqueta_nodo(%{"tipo" => "vista_previa", "propiedades" => %{"campo" => nil}}), do: "Vista previa — (sin configurar)"
  defp etiqueta_nodo(%{"tipo" => "vista_previa", "propiedades" => %{"campo" => c}}), do: "Vista previa — #{c}"
  defp etiqueta_nodo(%{"tipo" => "etiqueta", "propiedades" => %{"texto" => t}}), do: "Etiqueta — #{t}"
  defp etiqueta_nodo(%{"tipo" => "alerta", "propiedades" => %{"nivel" => n}}), do: "Alerta (#{n})"
  defp etiqueta_nodo(%{"tipo" => "tarjeta", "propiedades" => %{"titulo" => t}}), do: "Tarjeta — #{t}"
  defp etiqueta_nodo(%{"tipo" => "fila"}), do: "Fila"
  defp etiqueta_nodo(%{"tipo" => "columna"}), do: "Columna"
  defp etiqueta_nodo(%{"tipo" => "panel"}), do: "Panel"
  defp etiqueta_nodo(%{"tipo" => "pestanas"}), do: "Pestañas"
  defp etiqueta_nodo(%{"tipo" => "pestana", "propiedades" => %{"titulo" => t}}), do: "Pestaña — #{t}"
  defp etiqueta_nodo(%{"tipo" => "grid", "propiedades" => %{"filas" => f, "columnas" => c}}), do: "Grid — #{f}×#{c}"
  defp etiqueta_nodo(%{"tipo" => "boton", "propiedades" => %{"etiqueta" => e}}), do: "Botón — #{e}"
  defp etiqueta_nodo(%{"tipo" => "resumen", "propiedades" => %{"etiqueta" => e}}), do: "Resumen/KPI — #{e}"
  defp etiqueta_nodo(%{"tipo" => "timeline"}), do: "Timeline"
  defp etiqueta_nodo(nodo), do: nodo["tipo"]

  # Ícono del nodo en el lienzo — para "campo" usa el tipo_filtro elegido en
  # la paleta si lo tiene (ej. muestra el ícono de calendario para un campo
  # de fecha), o el genérico si no.
  defp icono_de_nodo(%{"tipo" => "campo", "propiedades" => %{"tipo_filtro" => filtro}}) when filtro not in [nil, ""], do: filtro
  defp icono_de_nodo(nodo), do: nodo["tipo"]

  # Botón "Editar contenido →" — generaliza lo que antes solo tenía "grid"
  # ("Editar grid"): CUALQUIER tipos_grid_host/0 (Sección/Panel/Grid legado
  # — "pestana" usa su propio botón sin ambigüedad porque nunca es plural)
  # entra a su propio grid con el mismo evento `entrar_contenedor`.
  attr :id, :string, required: true

  defp boton_entrar(assigns) do
    ~H"""
    <button type="button" phx-click="entrar_contenedor" phx-value-id={@id}
      class="px-3 py-1.5 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700 text-center">
      Editar contenido →
    </button>
    """
  end

  attr :nodo, :map, required: true
  attr :campos, :list, required: true
  attr :catalogos_relacionables, :list, required: true
  attr :catalogos_disponibles, :list, default: []
  attr :catalogos_detalle_disponibles, :list, default: []
  attr :resumen_catalogo, :string, default: nil
  attr :resumen_funcion, :string, default: "SUM"
  attr :resumen_campo, :string, default: nil
  attr :lookup_catalogo, :string, default: nil
  attr :lookup_id, :string, default: nil
  attr :lookup_campo, :string, default: nil
  attr :herramienta_calculado, :string, default: nil
  attr :definicion, :map, default: %{}
  attr :nombre, :string, default: nil
  attr :registro_muestra_id, :any, default: nil
  attr :current_scope, :any, default: nil

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
      <.toggle_switch name="colapsable" checked={@nodo["propiedades"]["colapsable"] == true} label="Colapsable (se puede plegar/desplegar)" />
      <div :if={@nodo["propiedades"]["colapsable"] == true} class="flex flex-col gap-2 pl-1">
        <.toggle_switch name="iniciar_expandida" checked={@nodo["propiedades"]["iniciar_expandida"] != false} label="Iniciar expandida" />
        <.toggle_switch name="recordar_estado" checked={@nodo["propiedades"]["recordar_estado"] == true} label="Recordar si el usuario la dejó abierta/cerrada" />
      </div>
      <.toggle_switch name="contador_campos" checked={@nodo["propiedades"]["contador_campos"] == true} label="Mostrar contador de campos" />
      <.toggle_switch name="visible" checked={@nodo["propiedades"]["visible"] != false} label="Visible en la Ficha 360°" />
    </form>
    <.boton_entrar id={@nodo["id"]} />
    """
  end

  defp panel_propiedades(%{nodo: %{"tipo" => "tarjeta"}} = assigns) do
    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Tipo</label>
        <select name="tipo" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="informacion" selected={(@nodo["propiedades"]["tipo"] || "informacion") == "informacion"}>Información</option>
          <option value="metrica" selected={@nodo["propiedades"]["tipo"] == "metrica"}>Métrica</option>
          <option value="estado" selected={@nodo["propiedades"]["tipo"] == "estado"}>Estado</option>
          <option value="accion" selected={@nodo["propiedades"]["tipo"] == "accion"}>Acción</option>
          <option value="ayuda" selected={@nodo["propiedades"]["tipo"] == "ayuda"}>Ayuda</option>
        </select>
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Ícono (emoji, opcional)</label>
        <input type="text" name="icono" value={@nodo["propiedades"]["icono"]} maxlength="4" class="w-20 border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Título</label>
        <input type="text" name="titulo" value={@nodo["propiedades"]["titulo"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">{if @nodo["propiedades"]["tipo"] == "metrica", do: "Valor", else: "Texto"}</label>
        <textarea :if={@nodo["propiedades"]["tipo"] != "metrica"} name="texto" rows="2" class="w-full border border-gray-300 rounded px-2 py-1.5">{@nodo["propiedades"]["texto"]}</textarea>
        <input :if={@nodo["propiedades"]["tipo"] == "metrica"} type="text" name="texto" value={@nodo["propiedades"]["texto"]}
          placeholder="Ej. 2,350" class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div :if={@nodo["propiedades"]["tipo"] == "estado"}>
        <label class="block text-gray-500 mb-1">Color</label>
        <.swatch_picker name="color" valor={@nodo["propiedades"]["color"] || "gris"} incluir_ninguno={false} />
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
      <div>
        <label class="block text-gray-500 mb-0.5">Ícono (emoji, opcional)</label>
        <input type="text" name="icono" value={@nodo["propiedades"]["icono"]} maxlength="4" class="w-20 border border-gray-300 rounded px-2 py-1.5" />
      </div>
    </form>
    <.boton_entrar id={@nodo["id"]} />
    """
  end

  # El contenido de cada pestaña es SU PROPIO grid (ver moduledoc "Grid 2D"
  # de MetaPlantillas) — pero "pestanas" (el conmutador en sí) no lo es:
  # sus hijos son las pestañas literales, nunca celdas. Por eso acá se
  # entra a CADA "pestana" por separado, no a "pestanas" mismo.
  defp panel_propiedades(%{nodo: %{"tipo" => "pestanas"}} = assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5 text-xs">
      <form phx-change="actualizar_propiedad" class="mb-1.5">
        <label class="block text-gray-500 mb-0.5">Tipo</label>
        <select name="tipo" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="pestanas" selected={(@nodo["propiedades"]["tipo"] || "pestanas") == "pestanas"}>Pestañas (barra horizontal)</option>
          <option value="acordeon" selected={@nodo["propiedades"]["tipo"] == "acordeon"}>Acordeón (se despliegan una debajo de otra)</option>
          <option value="paso_a_paso" selected={@nodo["propiedades"]["tipo"] == "paso_a_paso"}>Paso a paso (una a la vez, con Anterior/Siguiente)</option>
          <option value="menu_lateral" selected={@nodo["propiedades"]["tipo"] == "menu_lateral"}>Menú lateral (lista vertical a la izquierda)</option>
        </select>
      </form>
      <form phx-change="actualizar_propiedad" class="mb-1.5">
        <label class="flex items-center gap-1.5">
          <input type="hidden" name="contador_campos" value="false" />
          <input type="checkbox" name="contador_campos" value="true" checked={@nodo["propiedades"]["contador_campos"] == true} class="accent-purple-600" />
          Mostrar contador de campos junto al título de cada pestaña
        </label>
      </form>
      <p class="text-gray-500 mb-0.5">Entrá a cada pestaña para editar su contenido.</p>
      <div :for={p <- @nodo["hijos"]} class="flex items-center gap-1">
        <button type="button" phx-click="entrar_contenedor" phx-value-id={p["id"]}
          class="flex-1 flex items-center justify-between px-2.5 py-1.5 rounded-lg border border-gray-200 text-gray-600 font-semibold hover:border-purple-400 hover:text-purple-700 hover:bg-purple-50/50">
          {p["propiedades"]["titulo"] || "Pestaña"} <span>→</span>
        </button>
        <button :if={length(@nodo["hijos"]) > 1} type="button" phx-click="eliminar_pestana" phx-value-id={p["id"]}
          title="Quitar esta pestaña (se pierde su contenido)"
          class="px-2 py-1.5 rounded-lg border border-gray-200 text-gray-400 hover:border-red-300 hover:text-red-600">
          ✕
        </button>
      </div>
      <button type="button" phx-click="agregar_pestana" phx-value-id={@nodo["id"]}
        class="mt-1 px-2.5 py-1.5 rounded-lg border border-dashed border-gray-300 text-gray-500 font-semibold hover:border-purple-400 hover:text-purple-700">
        + Agregar pestaña
      </button>
    </div>
    """
  end

  defp panel_propiedades(%{nodo: %{"tipo" => "panel"}} = assigns) do
    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Distribución</label>
        <select name="distribucion" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="grid" selected={(@nodo["propiedades"]["distribucion"] || "grid") == "grid"}>Grid (posición libre, como hoy)</option>
          <option value="vertical" selected={@nodo["propiedades"]["distribucion"] == "vertical"}>Vertical (uno debajo del otro)</option>
          <option value="horizontal" selected={@nodo["propiedades"]["distribucion"] == "horizontal"}>Horizontal (uno al lado del otro)</option>
          <option value="automatica" selected={@nodo["propiedades"]["distribucion"] == "automatica"}>Automática (uno al lado del otro, pasa de línea si no entra)</option>
        </select>
      </div>
      <div :if={@nodo["propiedades"]["distribucion"] not in [nil, "grid"]}>
        <label class="block text-gray-500 mb-0.5">Separación</label>
        <select name="separacion" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="compacto" selected={@nodo["propiedades"]["separacion"] == "compacto"}>Compacta</option>
          <option value="normal" selected={(@nodo["propiedades"]["separacion"] || "normal") == "normal"}>Normal</option>
          <option value="amplio" selected={@nodo["propiedades"]["separacion"] == "amplio"}>Amplia</option>
        </select>
      </div>
    </form>
    <p class="text-gray-400 mt-2 mb-2">
      <%= if @nodo["propiedades"]["distribucion"] in [nil, "grid"] do %>
        Con Grid, acomodá los componentes a mano (fila/columna) entrando al panel.
      <% else %>
        Con esta distribución el orden es el mismo en que agregaste los componentes — entrá al panel para agregar/quitar, no hace falta acomodarlos en celdas.
      <% end %>
    </p>
    <.boton_entrar id={@nodo["id"]} />
    """
  end

  # "fila"/"columna" quedan solo por compatibilidad con datos viejos (ver
  # MetaPlantillas.tipos_contenedor/0) — ya no se generan desde acá, así
  # que no hace falta un "Editar contenido" (no son tipos_grid_host/0).
  defp panel_propiedades(%{nodo: %{"tipo" => tipo}} = assigns) when tipo in ["fila", "columna"] do
    ~H"""
    <p class="text-gray-400">Sin propiedades.</p>
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

  # Constructor de chips — la fórmula sigue siendo el mismo string de
  # siempre (Formula.evaluar/2 no cambió), esto solo la arma por clicks en
  # vez de tipeándola. @formula_tokens sale del MISMO tokenizer que usa el
  # evaluador (Formula.tokens_para_mostrar/1), así que lo que se ve acá
  # nunca se desincroniza de lo que realmente se va a evaluar.
  defp panel_propiedades(%{nodo: %{"tipo" => "campo_calculado"}} = assigns) do
    formula_tokens = Formula.tokens_para_mostrar(assigns.nodo["propiedades"]["formula"] || "")

    vista_previa =
      vista_previa_calculado(assigns.nombre, assigns.registro_muestra_id, assigns.campos, assigns.definicion, assigns.nodo, assigns.current_scope)

    # Asistente (2026-08-14): la primera vez que se abre un campo_calculado
    # YA armado (formula no vacía), @herramienta_calculado todavía es nil
    # (se resetea al seleccionar cualquier nodo, ver handle_event
    # "seleccionar_nodo") -- sin esto, reabrir un cálculo existente
    # mostraría el estado vacío "elegí una opción" en vez de la fórmula
    # que ya tiene. Una vez que el usuario clickea una opción (real
    # @herramienta_calculado, vía "seleccionar_herramienta_calculado"),
    # esa elección manda siempre.
    herramienta_efectiva =
      cond do
        assigns.herramienta_calculado not in [nil, ""] -> assigns.herramienta_calculado
        assigns.nodo["propiedades"]["formula"] not in [nil, ""] -> "formula"
        true -> nil
      end

    assigns =
      assigns
      |> assign(:formula_tokens, formula_tokens)
      |> assign(:vista_previa, vista_previa)
      |> assign(:herramienta_efectiva, herramienta_efectiva)

    ~H"""
    <div class="flex flex-col gap-2.5 text-xs">
      <form phx-change="actualizar_propiedad">
        <label class="block text-gray-500 mb-0.5">Etiqueta</label>
        <input type="text" name="etiqueta" value={@nodo["propiedades"]["etiqueta"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </form>

      <div>
        <p class="text-gray-500 font-semibold mb-1.5">¿Cómo querés obtener este valor?</p>
        <div class="grid grid-cols-2 gap-1.5">
          <button :for={{herramienta, simbolo, etiqueta} <- herramientas_calculado(@catalogos_disponibles)}
            type="button" phx-click="seleccionar_herramienta_calculado" phx-value-herramienta={herramienta}
            class={[
              "flex flex-col items-center gap-0.5 px-2 py-2.5 rounded-lg border text-center",
              @herramienta_efectiva == herramienta && "border-purple-400 bg-purple-50 text-purple-700",
              @herramienta_efectiva != herramienta && "border-gray-200 text-gray-500 hover:border-gray-300 hover:bg-gray-50"
            ]}>
            <span class="text-base font-bold">{simbolo}</span>
            <span class="text-[11px] font-semibold">{etiqueta}</span>
          </button>
        </div>
      </div>

      <p :if={@herramienta_efectiva in [nil, ""]} class="text-gray-400 text-center py-2">
        Elegí una opción arriba para empezar.
      </p>

      <div :if={@herramienta_efectiva not in [nil, ""]}>
        <label class="block text-gray-500 mb-1">Fórmula</label>

        <div class="flex flex-wrap items-center gap-1.5 min-h-[38px] border border-gray-300 rounded-lg px-2 py-1.5 bg-gray-50">
          <span :for={{token, i} <- Enum.with_index(@formula_tokens)} class={chip_class(token)}>
            {texto_legible_token(token, @campos)}
            <button type="button" phx-click="formula_quitar_token" phx-value-indice={i} class="opacity-50 hover:opacity-100">✕</button>
          </span>
          <span :if={@formula_tokens == []} class="text-gray-400">Vacío — agregá un campo o un operador abajo</span>
        </div>

        <div :if={@herramienta_efectiva in ["formula", "condicion"]}>
          <div class="flex flex-wrap gap-1 mt-2">
            <button :for={c <- @campos} type="button" phx-click="formula_agregar_campo" phx-value-campo={c.schema_context_field}
              class="px-2 py-1 rounded-md border border-purple-200 text-purple-700 bg-purple-50 hover:bg-purple-100 font-semibold">
              {c.schema_context_properties["etiqueta"]}
            </button>
          </div>

          <div class="flex flex-wrap gap-1 mt-1.5">
            <button :for={{campo, etiqueta} <- [{"hoy", "Hoy"}, {"usuario_actual", "Usuario actual"}, {"empresa_activa", "Empresa activa"}]}
              type="button" phx-click="formula_agregar_campo" phx-value-campo={campo}
              class="px-2 py-1 rounded-md border border-teal-200 text-teal-700 bg-teal-50 hover:bg-teal-100 font-semibold">
              {etiqueta}
            </button>
          </div>

          <div :if={otros_campos_calculados(@definicion, @nodo["id"]) != []} class="flex flex-wrap gap-1 mt-1.5">
            <button :for={etiqueta <- otros_campos_calculados(@definicion, @nodo["id"])}
              type="button" phx-click="formula_agregar_campo" phx-value-campo={etiqueta}
              class="px-2 py-1 rounded-md border border-indigo-200 text-indigo-700 bg-indigo-50 hover:bg-indigo-100 font-semibold">
              ∑ {etiqueta}
            </button>
          </div>

          <div class="flex flex-wrap items-center gap-1 mt-1.5">
            <button :for={{simbolo, real} <- [{"+", "+"}, {"−", "-"}, {"×", "*"}, {"÷", "/"}, {"(", "("}, {")", ")"}]}
              type="button" phx-click="formula_agregar_operador" phx-value-op={real}
              class="w-7 h-7 flex items-center justify-center rounded-full border border-gray-300 text-gray-600 hover:border-purple-400 hover:text-purple-700 font-bold">
              {simbolo}
            </button>

            <input type="number" step="any" placeholder="número + Enter" phx-keyup="formula_agregar_numero" phx-key="Enter"
              id={"formula-num-" <> @nodo["id"] <> "-" <> Integer.to_string(length(@formula_tokens))}
              class="w-24 border border-gray-300 rounded px-1.5 py-1" />

            <button :if={@formula_tokens != []} type="button" phx-click="formula_vaciar"
              class="ml-auto px-2 py-1 rounded-md border border-red-200 text-red-500 hover:bg-red-50">
              Vaciar
            </button>
          </div>
        </div>

        <div :if={@herramienta_efectiva == "condicion"} class="mt-2.5 pt-2.5 border-t border-gray-100">
          <p class="text-gray-500 font-semibold mb-1">Condición — SI / ENTONCES / SI NO</p>
          <div class="flex flex-wrap items-center gap-1 mb-1.5">
            <button :for={{simbolo, real} <- [{"SI", "IF"}, {"ENTONCES", "THEN"}, {"SI NO", "ELSE"}]}
              type="button" phx-click="formula_agregar_operador" phx-value-op={real}
              class="px-2 py-1 rounded-md border border-amber-200 text-amber-700 bg-amber-50 hover:bg-amber-100 font-bold">
              {simbolo}
            </button>
          </div>
          <div class="flex flex-wrap items-center gap-1">
            <button :for={{simbolo, real} <- [{">", ">"}, {"<", "<"}, {"≥", ">="}, {"≤", "<="}, {"=", "=="}, {"≠", "!="}]}
              type="button" phx-click="formula_agregar_operador" phx-value-op={real}
              class="w-7 h-7 flex items-center justify-center rounded-full border border-gray-300 text-gray-600 hover:border-purple-400 hover:text-purple-700 font-bold">
              {simbolo}
            </button>
            <input type="text" placeholder="texto + Enter" phx-keyup="formula_agregar_texto" phx-key="Enter"
              id={"formula-str-" <> @nodo["id"] <> "-" <> Integer.to_string(length(@formula_tokens))}
              class="w-28 border border-gray-300 rounded px-1.5 py-1" />
          </div>
          <p class="text-gray-400 mt-1">
            Ej.: <span class="font-mono">SI {"{stock_actual}"} &gt; {"{stock_minimo}"} ENTONCES "Disponible" SI NO "Agotado"</span> — solo al armar la fórmula entera, no adentro de un cálculo.
          </p>
        </div>

        <div :if={@herramienta_efectiva == "resumen" and @catalogos_disponibles != []} class="mt-2.5 pt-2.5 border-t border-gray-100">
          <p class="text-gray-500 font-semibold mb-1">Resumen — agregado de otro catálogo</p>
          <div class="flex flex-col gap-1.5">
            <select phx-change="resumen_set_funcion" name="funcion" class="w-full border border-gray-300 rounded px-2 py-1.5">
              <option value="SUM" selected={@resumen_funcion == "SUM"}>SUM — sumar</option>
              <option value="COUNT" selected={@resumen_funcion == "COUNT"}>COUNT — contar registros</option>
              <option value="AVG" selected={@resumen_funcion == "AVG"}>AVG — promedio</option>
              <option value="MIN" selected={@resumen_funcion == "MIN"}>MIN — mínimo</option>
              <option value="MAX" selected={@resumen_funcion == "MAX"}>MAX — máximo</option>
            </select>

            <select phx-change="resumen_set_catalogo" name="catalogo" class="w-full border border-gray-300 rounded px-2 py-1.5">
              <option value="" selected={@resumen_catalogo in [nil, ""]}>Catálogo…</option>
              <option :for={cat <- @catalogos_disponibles} value={cat.nombre} selected={@resumen_catalogo == cat.nombre}>
                {cat.etiqueta}
              </option>
            </select>

            <select :if={@resumen_funcion != "COUNT"} phx-change="resumen_set_campo" name="campo" class="w-full border border-gray-300 rounded px-2 py-1.5">
              <option value="" selected={@resumen_campo in [nil, ""]}>Campo…</option>
              <option :for={c <- campos_de(@catalogos_disponibles, @resumen_catalogo)} value={c.schema_context_field} selected={@resumen_campo == c.schema_context_field}>
                {c.schema_context_properties["etiqueta"]}
              </option>
            </select>

            <button type="button" phx-click="formula_agregar_agregado"
              disabled={@resumen_catalogo in [nil, ""] or (@resumen_funcion != "COUNT" and @resumen_campo in [nil, ""])}
              class="px-2 py-1.5 rounded-md bg-purple-600 text-white font-semibold hover:bg-purple-700 disabled:bg-gray-200 disabled:text-gray-400 disabled:cursor-not-allowed">
              + Agregar a la fórmula
            </button>
          </div>
        </div>

        <div :if={@herramienta_efectiva == "lookup" and @catalogos_disponibles != []} class="mt-2.5 pt-2.5 border-t border-gray-100">
          <p class="text-gray-500 font-semibold mb-1">Registro puntual de otro catálogo</p>
          <div class="flex flex-col gap-1.5">
            <select phx-change="lookup_set_catalogo" name="catalogo" class="w-full border border-gray-300 rounded px-2 py-1.5">
              <option value="" selected={@lookup_catalogo in [nil, ""]}>Catálogo…</option>
              <option :for={cat <- @catalogos_disponibles} value={cat.nombre} selected={@lookup_catalogo == cat.nombre}>
                {cat.etiqueta}
              </option>
            </select>

            <input type="number" min="1" step="1" phx-change="lookup_set_id" name="registro_id" value={@lookup_id}
              placeholder="ID del registro" class="w-full border border-gray-300 rounded px-2 py-1.5" />

            <select :if={@lookup_catalogo not in [nil, ""]} phx-change="lookup_set_campo" name="campo" class="w-full border border-gray-300 rounded px-2 py-1.5">
              <option value="" selected={@lookup_campo in [nil, ""]}>Campo…</option>
              <option :for={c <- campos_de(@catalogos_disponibles, @lookup_catalogo)} value={c.schema_context_field} selected={@lookup_campo == c.schema_context_field}>
                {c.schema_context_properties["etiqueta"]}
              </option>
            </select>

            <button type="button" phx-click="formula_agregar_lookup"
              disabled={@lookup_catalogo in [nil, ""] or @lookup_campo in [nil, ""] or not id_valido?(@lookup_id)}
              class="px-2 py-1.5 rounded-md bg-purple-600 text-white font-semibold hover:bg-purple-700 disabled:bg-gray-200 disabled:text-gray-400 disabled:cursor-not-allowed">
              + Agregar a la fórmula
            </button>
          </div>
        </div>

        <details :if={@catalogos_disponibles != []} class="mt-2">
          <summary class="cursor-pointer text-gray-400 hover:text-gray-600">Avanzado — escribir la fórmula como texto</summary>
          <div class="mt-1.5 pl-0.5">
            <input type="text" value={@nodo["propiedades"]["formula"]} phx-change="formula_set_texto"
              placeholder="{catalogo#id.campo}" class="w-full border border-gray-300 rounded px-2 py-1.5 font-mono mt-1" />
          </div>
        </details>
      </div>

      <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5">
        <div class="flex items-end gap-2">
          <div>
            <label class="block text-gray-500 mb-0.5">Mostrar como</label>
            <select name="formato" class="border border-gray-300 rounded px-2 py-1.5">
              <option value="numero" selected={(@nodo["propiedades"]["formato"] || "numero") == "numero"}>Número</option>
              <option value="moneda" selected={@nodo["propiedades"]["formato"] == "moneda"}>Moneda</option>
              <option value="porcentaje" selected={@nodo["propiedades"]["formato"] == "porcentaje"}>Porcentaje</option>
              <option value="semaforo" selected={@nodo["propiedades"]["formato"] == "semaforo"}>Semáforo</option>
              <option value="badge" selected={@nodo["propiedades"]["formato"] == "badge"}>Badge</option>
              <option value="progreso" selected={@nodo["propiedades"]["formato"] == "progreso"}>Barra de progreso</option>
              <option value="estrellas" selected={@nodo["propiedades"]["formato"] == "estrellas"}>Estrellas</option>
            </select>
          </div>
          <div>
            <label class="block text-gray-500 mb-0.5">Decimales</label>
            <input type="number" name="decimales" min="0" max="10" value={@nodo["propiedades"]["decimales"]} class="w-24 border border-gray-300 rounded px-2 py-1.5" />
          </div>
        </div>

        <div :if={@nodo["propiedades"]["formato"] == "semaforo"} class="flex items-end gap-2">
          <div>
            <label class="block text-gray-500 mb-0.5">Rojo hasta</label>
            <input type="number" step="any" name="semaforo_bajo" value={@nodo["propiedades"]["semaforo_bajo"]} placeholder="30" class="w-24 border border-gray-300 rounded px-2 py-1.5" />
          </div>
          <div>
            <label class="block text-gray-500 mb-0.5">Amarillo hasta</label>
            <input type="number" step="any" name="semaforo_alto" value={@nodo["propiedades"]["semaforo_alto"]} placeholder="70" class="w-24 border border-gray-300 rounded px-2 py-1.5" />
          </div>
          <p class="text-gray-400 pb-1.5">Más alto que esto: verde.</p>
        </div>

        <div :if={@nodo["propiedades"]["formato"] == "badge"}>
          <label class="block text-gray-500 mb-0.5">Color</label>
          <select name="color" class="w-full border border-gray-300 rounded px-2 py-1.5">
            <option value="gris" selected={(@nodo["propiedades"]["color"] || "gris") == "gris"}>Gris</option>
            <option value="purpura" selected={@nodo["propiedades"]["color"] == "purpura"}>Púrpura</option>
            <option value="azul" selected={@nodo["propiedades"]["color"] == "azul"}>Azul</option>
            <option value="verde" selected={@nodo["propiedades"]["color"] == "verde"}>Verde</option>
            <option value="amarillo" selected={@nodo["propiedades"]["color"] == "amarillo"}>Amarillo</option>
            <option value="rojo" selected={@nodo["propiedades"]["color"] == "rojo"}>Rojo</option>
          </select>
        </div>

        <div :if={@nodo["propiedades"]["formato"] == "progreso"}>
          <label class="block text-gray-500 mb-0.5">Valor máximo (100%)</label>
          <input type="number" step="any" name="progreso_maximo" value={@nodo["propiedades"]["progreso_maximo"]} placeholder="100" class="w-24 border border-gray-300 rounded px-2 py-1.5" />
        </div>

        <div :if={@nodo["propiedades"]["formato"] == "estrellas"}>
          <label class="block text-gray-500 mb-0.5">Cantidad de estrellas</label>
          <input type="number" min="1" max="10" name="estrellas_maximo" value={@nodo["propiedades"]["estrellas_maximo"]} placeholder="5" class="w-24 border border-gray-300 rounded px-2 py-1.5" />
        </div>
      </form>

      <p :if={@nodo["propiedades"]["formato"] in ["semaforo", "badge", "progreso", "estrellas"]} class="text-gray-400">
        La vista previa de acá abajo todavía muestra el número plano — el color/barra/estrellas reales se ven en la Ficha 360° publicada.
      </p>

      <div class="mt-1 pt-2.5 border-t border-gray-100">
        <p class="text-gray-500 font-semibold mb-1">Vista previa — contra un registro real</p>
        <div class="rounded-lg border border-gray-200 overflow-hidden">
          <div :if={match?({:ok, _}, @vista_previa)} class="px-2.5 py-2 bg-white">
            <span class="text-gray-900 font-bold text-sm">{Formula.formatear(@vista_previa, @nodo["propiedades"])}</span>
          </div>
          <p :if={match?({:error, _}, @vista_previa)} class="px-2.5 py-2 text-amber-700 bg-amber-50">
            {mensaje_error_formula(@vista_previa)}
          </p>
        </div>
      </div>
    </div>
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
    campo_referencia = assigns.nodo["propiedades"]["campo_referencia"]
    campos_del_destino = Enum.find(assigns.catalogos_disponibles, &(&1.nombre == catalogo_destino))
    campos_del_destino = (campos_del_destino && campos_del_destino.campos) || []
    campos_destino_actuales = assigns.nodo["propiedades"]["campos_destino"] || []

    vista_previa =
      vista_previa_autocompletar(
        assigns.nombre,
        assigns.registro_muestra_id,
        campo_referencia,
        catalogo_destino,
        campos_destino_actuales,
        campos_del_destino
      )

    assigns =
      assigns
      |> assign(:campos_del_destino, campos_del_destino)
      |> assign(:campos_destino_actuales, campos_destino_actuales)
      |> assign(:vista_previa, vista_previa)

    ~H"""
    <div class="flex flex-col gap-3 text-xs">
      <div>
        <div class="flex items-center gap-1.5 mb-1">
          <span class="w-4 h-4 rounded-full bg-purple-600 text-white flex items-center justify-center font-bold" style="font-size:9px">1</span>
          <label class="text-gray-500 font-semibold">Relación</label>
        </div>
        <form phx-change="actualizar_propiedad" class="flex flex-col gap-1.5 pl-5">
          <select name="campo_referencia" class="w-full border border-gray-300 rounded px-2 py-1.5">
            <option value="" selected={is_nil(@nodo["propiedades"]["campo_referencia"])}>Cuando cambie…</option>
            <option :for={c <- @campos} value={c.schema_context_field} selected={@nodo["propiedades"]["campo_referencia"] == c.schema_context_field}>
              {c.schema_context_properties["etiqueta"]}
            </option>
          </select>
          <select name="catalogo_destino" class="w-full border border-gray-300 rounded px-2 py-1.5">
            <option value="" selected={is_nil(@nodo["propiedades"]["catalogo_destino"])}>…buscar en</option>
            <option :for={cat <- @catalogos_disponibles} value={cat.nombre} selected={@nodo["propiedades"]["catalogo_destino"] == cat.nombre}>
              {cat.etiqueta}
            </option>
          </select>
        </form>
        <p class="text-gray-400 mt-1 pl-5">Cualquier campo cuyo valor sea un número entero funciona (no hace falta que esté marcado como "referencia").</p>
      </div>

      <div>
        <div class="flex items-center gap-1.5 mb-1">
          <span class="w-4 h-4 rounded-full bg-purple-600 text-white flex items-center justify-center font-bold" style="font-size:9px">2</span>
          <label class="text-gray-500 font-semibold">Campos a mostrar</label>
        </div>
        <form phx-change="actualizar_propiedad" class="pl-5">
          <p :if={@campos_del_destino == []} class="text-gray-400">Elegí un catálogo destino en el paso 1 primero.</p>
          <input type="hidden" name="campos_destino[]" value="" />
          <label :for={c <- @campos_del_destino} class="flex items-center gap-1.5 mb-1">
            <input type="checkbox" name="campos_destino[]" value={c.schema_context_field} checked={c.schema_context_field in @campos_destino_actuales} class="accent-purple-600" />
            {c.schema_context_properties["etiqueta"]}
          </label>
          <label class="block text-gray-500 mt-2 mb-0.5">Título del bloque (opcional)</label>
          <input type="text" name="titulo" value={@nodo["propiedades"]["titulo"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />

          <label class="block text-gray-500 mt-2 mb-0.5">Mostrar</label>
          <select name="mostrar" class="w-full border border-gray-300 rounded px-2 py-1.5">
            <option value="lista" selected={(@nodo["propiedades"]["mostrar"] || "lista") == "lista"}>Lista (una fila por campo)</option>
            <option value="tarjeta" selected={@nodo["propiedades"]["mostrar"] == "tarjeta"}>Tarjeta (grilla de 2 columnas, compacta)</option>
            <option value="resumen" selected={@nodo["propiedades"]["mostrar"] == "resumen"}>Resumen (una sola línea)</option>
            <option value="campos" selected={@nodo["propiedades"]["mostrar"] == "campos"}>Campos (como un formulario de solo lectura)</option>
          </select>
        </form>
      </div>

      <div>
        <div class="flex items-center gap-1.5 mb-1">
          <span class="w-4 h-4 rounded-full bg-purple-600 text-white flex items-center justify-center font-bold" style="font-size:9px">3</span>
          <label class="text-gray-500 font-semibold">Vista previa</label>
        </div>
        <div class="pl-5 rounded-lg border border-gray-200 overflow-hidden">
          <div :if={match?({:ok, _}, @vista_previa)} class="divide-y divide-gray-50">
            <div :for={{etiqueta, valor} <- elem(@vista_previa, 1)} class="flex items-center gap-2 px-2.5 py-1.5 bg-white">
              <span class="text-gray-500 w-24 flex-shrink-0 truncate">{etiqueta}</span>
              <span class="text-gray-900 font-semibold truncate">{valor}</span>
            </div>
          </div>
          <p :if={match?({:error, _}, @vista_previa)} class="px-2.5 py-2 text-gray-400 bg-gray-50">
            {mensaje_vista_previa(@vista_previa)}
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp panel_propiedades(%{nodo: %{"tipo" => "divisor"}} = assigns) do
    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Título (opcional)</label>
        <input type="text" name="titulo" value={@nodo["propiedades"]["titulo"]} placeholder="Ej. Datos fiscales"
          class="w-full border border-gray-300 rounded px-2 py-1.5" />
        <p class="text-gray-400 mt-1">Sin título es una línea simple. Con título, el texto queda en el medio de la línea.</p>
      </div>
    </form>
    """
  end

  # Vista previa -- muestra un archivo (imagen/PDF) cuya URL YA vive en un
  # campo de texto de ESTE catálogo (ej. lo trajo una integración externa,
  # o alguien la pegó a mano) -- sin subida de archivos ni storage propio,
  # a propósito (alcance confirmado 2026-08-14): eso es una pieza de
  # infraestructura aparte, mucho más grande.
  defp panel_propiedades(%{nodo: %{"tipo" => "vista_previa"}} = assigns) do
    campos_url = Enum.filter(assigns.campos, &(&1.schema_context_properties["tipo"] == "string"))
    assigns = assign(assigns, :campos_url, campos_url)

    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Campo con la URL del archivo</label>
        <select name="campo" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="" selected={is_nil(@nodo["propiedades"]["campo"])}>Elegir…</option>
          <option :for={c <- @campos_url} value={c.schema_context_field} selected={@nodo["propiedades"]["campo"] == c.schema_context_field}>
            {c.schema_context_properties["etiqueta"]}
          </option>
        </select>
        <p :if={@campos_url == []} class="text-gray-400 mt-1">Este catálogo no tiene campos de texto — creá uno para guardar la URL primero.</p>
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Título (opcional)</label>
        <input type="text" name="titulo" value={@nodo["propiedades"]["titulo"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Tipo</label>
        <select name="tipo" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="auto" selected={(@nodo["propiedades"]["tipo"] || "auto") == "auto"}>Automático (según la extensión del archivo)</option>
          <option value="imagen" selected={@nodo["propiedades"]["tipo"] == "imagen"}>Siempre imagen</option>
          <option value="pdf" selected={@nodo["propiedades"]["tipo"] == "pdf"}>Siempre PDF</option>
        </select>
      </div>
    </form>
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
        <label class="block text-gray-500 mb-0.5">Ícono (emoji, opcional)</label>
        <input type="text" name="icono" value={@nodo["propiedades"]["icono"]} maxlength="4" class="w-20 border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Estilo</label>
        <select name="estilo" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="parrafo" selected={@nodo["propiedades"]["estilo"] == "parrafo"}>Párrafo</option>
          <option value="titulo" selected={@nodo["propiedades"]["estilo"] == "titulo"}>Título</option>
          <option value="subtitulo" selected={@nodo["propiedades"]["estilo"] == "subtitulo"}>Subtítulo</option>
          <option value="ayuda" selected={@nodo["propiedades"]["estilo"] == "ayuda"}>Ayuda</option>
          <option value="nota" selected={@nodo["propiedades"]["estilo"] == "nota"}>Nota</option>
          <option value="advertencia" selected={@nodo["propiedades"]["estilo"] == "advertencia"}>Advertencia</option>
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
    campos_del_catalogo = campos_de_catalogo(assigns.catalogos_disponibles, assigns.nodo["propiedades"]["catalogo"])
    campos_actuales = assigns.nodo["propiedades"]["campos"] || []
    campos_lista = Enum.filter(campos_del_catalogo, &(&1.schema_context_properties["tipo"] == "enum"))
    campos_fecha = Enum.filter(campos_del_catalogo, &(&1.schema_context_properties["tipo"] == "date"))

    assigns =
      assigns
      |> assign(:campos_del_catalogo, campos_del_catalogo)
      |> assign(:campos_actuales, campos_actuales)
      |> assign(:campos_lista, campos_lista)
      |> assign(:campos_fecha, campos_fecha)

    ~H"""
    <div class="flex flex-col gap-2.5 text-xs">
      <form phx-change="actualizar_propiedad">
        <label class="block text-gray-500 mb-0.5">¿Qué registros relacionados querés mostrar?</label>
        <select name="catalogo" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="" selected={is_nil(@nodo["propiedades"]["catalogo"])}>Elegir catálogo…</option>
          <option :for={{c, etiqueta} <- @catalogos_relacionables} value={c} selected={@nodo["propiedades"]["catalogo"] == c}>
            {etiqueta}
          </option>
        </select>
        <p :if={@catalogos_relacionables == []} class="text-gray-400 mt-1">Ningún catálogo referencia a éste todavía.</p>
      </form>

      <p :if={@nodo["propiedades"]["catalogo"] in [nil, ""]} class="text-gray-400 text-center py-2">
        Elegí un catálogo arriba para configurar el resto.
      </p>

      <form :if={@nodo["propiedades"]["catalogo"] not in [nil, ""]} phx-change="actualizar_propiedad" class="flex flex-col gap-2.5">
        <div>
          <label class="block text-gray-500 mb-0.5">Título</label>
          <input type="text" name="titulo" value={@nodo["propiedades"]["titulo"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
        </div>
        <div>
          <label class="block text-gray-500 mb-1">Campos a mostrar</label>
          <input type="hidden" name="campos[]" value="" />
          <label :for={c <- @campos_del_catalogo} class="flex items-center gap-1.5 mb-1">
            <input type="checkbox" name="campos[]" value={c.schema_context_field} checked={c.schema_context_field in @campos_actuales} class="accent-purple-600" />
            {c.schema_context_properties["etiqueta"]}
          </label>
          <p :if={@campos_actuales == []} class="text-gray-400 mt-1">Sin nada tildado, se muestra la descripción de siempre + el id.</p>
        </div>
        <div>
          <label class="block text-gray-500 mb-0.5">Vista</label>
          <select name="vista" class="w-full border border-gray-300 rounded px-2 py-1.5">
            <option value="tabla" selected={(@nodo["propiedades"]["vista"] || "tabla") == "tabla"}>Tabla (filas y columnas)</option>
            <option value="tarjetas" selected={@nodo["propiedades"]["vista"] == "tarjetas"}>Tarjetas (grilla de bloques)</option>
            <option value="kanban" selected={@nodo["propiedades"]["vista"] == "kanban"}>Kanban (columnas por Estado/Lista)</option>
            <option value="calendario" selected={@nodo["propiedades"]["vista"] == "calendario"}>Calendario (agenda por fecha)</option>
          </select>
        </div>
        <div :if={@nodo["propiedades"]["vista"] == "kanban"}>
          <label class="block text-gray-500 mb-0.5">Agrupar por</label>
          <select name="kanban_campo" class="w-full border border-gray-300 rounded px-2 py-1.5">
            <option value="__estado__" selected={(@nodo["propiedades"]["kanban_campo"] || "__estado__") == "__estado__"}>Estado del registro</option>
            <option :for={c <- @campos_lista} value={c.schema_context_field} selected={@nodo["propiedades"]["kanban_campo"] == c.schema_context_field}>
              {c.schema_context_properties["etiqueta"]}
            </option>
          </select>
          <p :if={@campos_lista == []} class="text-gray-400 mt-1">Ese catálogo no tiene campos tipo Lista además del Estado.</p>
        </div>
        <div :if={@nodo["propiedades"]["vista"] == "calendario"}>
          <label class="block text-gray-500 mb-0.5">Ubicar por (campo Fecha)</label>
          <select name="calendario_campo" class="w-full border border-gray-300 rounded px-2 py-1.5">
            <option value="" selected={is_nil(@nodo["propiedades"]["calendario_campo"])}>Elegir…</option>
            <option :for={c <- @campos_fecha} value={c.schema_context_field} selected={@nodo["propiedades"]["calendario_campo"] == c.schema_context_field}>
              {c.schema_context_properties["etiqueta"]}
            </option>
          </select>
          <p :if={@campos_fecha == []} class="text-gray-400 mt-1">Ese catálogo no tiene campos tipo Fecha.</p>
        </div>
      </form>
    </div>
    """
  end

  # "Lista rápida" -- versión liviana de Tabla relacionada (como el feed
  # de actividades de un CRM): mismos datos (@relaciones, misma
  # columnas_tabla_relacion/2), pero acotada a los primeros N registros y
  # sin encabezados de columna, un ítem clickeable por línea.
  defp panel_propiedades(%{nodo: %{"tipo" => "lista_rapida"}} = assigns) do
    campos_del_catalogo = campos_de_catalogo(assigns.catalogos_disponibles, assigns.nodo["propiedades"]["catalogo"])
    campos_actuales = assigns.nodo["propiedades"]["campos"] || []

    assigns =
      assigns
      |> assign(:campos_del_catalogo, campos_del_catalogo)
      |> assign(:campos_actuales, campos_actuales)

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
      <div>
        <label class="block text-gray-500 mb-1">Campos a mostrar (línea chica debajo del título de cada ítem)</label>
        <p :if={@campos_del_catalogo == []} class="text-gray-400">Elegí un catálogo relacionado arriba primero.</p>
        <input type="hidden" name="campos[]" value="" />
        <label :for={c <- @campos_del_catalogo} class="flex items-center gap-1.5 mb-1">
          <input type="checkbox" name="campos[]" value={c.schema_context_field} checked={c.schema_context_field in @campos_actuales} class="accent-purple-600" />
          {c.schema_context_properties["etiqueta"]}
        </label>
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Cuántos mostrar</label>
        <input type="number" name="limite" min="1" max="50" value={@nodo["propiedades"]["limite"]} placeholder="5" class="w-24 border border-gray-300 rounded px-2 py-1.5" />
        <p class="text-gray-400 mt-1">Si hay más, se muestra "y N más…" al final (sin link a una lista completa todavía).</p>
      </div>
    </form>
    """
  end

  # "Renglones de detalle" — distinto de "Tabla relacionada"/"Lista rápida"
  # de arriba (esos son por campo "referencia"): acá el <select> es sobre
  # @catalogos_detalle_disponibles, los catálogos detalle REALES de este
  # maestro (Productos/Pagos/Notas, vía schema_encabezado_id) — ver
  # nodo_plantilla_render/1 en FichaLive, cláusula "renglones".
  defp panel_propiedades(%{nodo: %{"tipo" => "renglones"}} = assigns) do
    detalle_elegido = Enum.find(assigns.catalogos_detalle_disponibles, &(&1.nombre == assigns.nodo["propiedades"]["catalogo"]))
    columnas_del_detalle = (detalle_elegido && detalle_elegido.columnas) || []
    columnas_numericas = Enum.filter(columnas_del_detalle, &(&1.schema_context_properties["tipo"] in ["integer", "decimal"]))
    campos_actuales = assigns.nodo["propiedades"]["campos"] || []

    assigns =
      assigns
      |> assign(:columnas_del_detalle, columnas_del_detalle)
      |> assign(:columnas_numericas, columnas_numericas)
      |> assign(:campos_actuales, campos_actuales)

    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">¿Cuál detalle?</label>
        <select name="catalogo" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="" selected={is_nil(@nodo["propiedades"]["catalogo"])}>Elegir…</option>
          <option :for={d <- @catalogos_detalle_disponibles} value={d.nombre} selected={@nodo["propiedades"]["catalogo"] == d.nombre}>
            {d.etiqueta}
          </option>
        </select>
        <p :if={@catalogos_detalle_disponibles == []} class="text-gray-400 mt-1">Este catálogo no tiene ningún detalle configurado.</p>
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Título</label>
        <input type="text" name="titulo" value={@nodo["propiedades"]["titulo"]} placeholder={(@catalogos_detalle_disponibles |> Enum.find(&(&1.nombre == @nodo["propiedades"]["catalogo"])) || %{etiqueta: "Renglones"}).etiqueta}
          class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-1">Columnas a mostrar</label>
        <p :if={@columnas_del_detalle == []} class="text-gray-400">Elegí un detalle arriba primero.</p>
        <input type="hidden" name="campos[]" value="" />
        <label :for={c <- @columnas_del_detalle} class="flex items-center gap-1.5 mb-1">
          <input type="checkbox" name="campos[]" value={c.schema_context_field} checked={c.schema_context_field in @campos_actuales} class="accent-purple-600" />
          {c.schema_context_properties["etiqueta"]}
        </label>
        <p class="text-gray-400 mt-1">Sin nada marcado, se muestran las columnas que ese detalle ya usa en su propia tabla.</p>
      </div>
      <.toggle_switch name="mostrar_total" checked={@nodo["propiedades"]["mostrar_total"] == true} label="Mostrar total al pie" />
      <div :if={@nodo["propiedades"]["mostrar_total"] == true}>
        <label class="block text-gray-500 mb-0.5">Campo a sumar</label>
        <select name="campo_total" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="" selected={is_nil(@nodo["propiedades"]["campo_total"])}>Elegir…</option>
          <option :for={c <- @columnas_numericas} value={c.schema_context_field} selected={@nodo["propiedades"]["campo_total"] == c.schema_context_field}>
            {c.schema_context_properties["etiqueta"]}
          </option>
        </select>
        <p :if={@columnas_numericas == []} class="text-gray-400 mt-1">Ese detalle no tiene campos numéricos.</p>
      </div>
    </form>
    """
  end

  defp panel_propiedades(%{nodo: %{"tipo" => "grid"}} = assigns) do
    ~H"""
    <div class="flex flex-col gap-2.5 text-xs">
      <p class="text-gray-500">{@nodo["propiedades"]["filas"]} filas × {@nodo["propiedades"]["columnas"]} columnas</p>
      <form phx-change="actualizar_propiedad">
        <label class="block text-gray-500 mb-0.5">Espaciado entre celdas</label>
        <select name="gap" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="compacto" selected={@nodo["propiedades"]["gap"] == "compacto"}>Compacto</option>
          <option value="normal" selected={(@nodo["propiedades"]["gap"] || "normal") == "normal"}>Normal</option>
          <option value="amplio" selected={@nodo["propiedades"]["gap"] == "amplio"}>Amplio</option>
        </select>
      </form>
      <.boton_entrar id={@nodo["id"]} />
    </div>
    """
  end

  defp panel_propiedades(%{nodo: %{"tipo" => "boton"}} = assigns) do
    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Etiqueta</label>
        <input type="text" name="etiqueta" value={@nodo["propiedades"]["etiqueta"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Acción (transición) a disparar</label>
        <input type="text" name="accion" value={@nodo["propiedades"]["accion"]} placeholder="ej. guardar, aprobar, baja"
          class="w-full border border-gray-300 rounded px-2 py-1.5" />
        <p class="text-gray-400 mt-1">
          Mismo nombre de "accion" configurado en las transiciones de este catálogo — si no aplica al estado actual del registro, el botón queda deshabilitado solo.
        </p>
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Estilo</label>
        <select name="estilo" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="primario" selected={(@nodo["propiedades"]["estilo"] || "primario") == "primario"}>Primario (relleno)</option>
          <option value="secundario" selected={@nodo["propiedades"]["estilo"] == "secundario"}>Secundario (borde)</option>
        </select>
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Dónde mostrarlo</label>
        <select name="ubicacion" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="cuerpo" selected={(@nodo["propiedades"]["ubicacion"] || "cuerpo") == "cuerpo"}>Donde lo coloqué (dentro del cuerpo)</option>
          <option value="pie" selected={@nodo["propiedades"]["ubicacion"] == "pie"}>Pie del formulario (fijo al final, siempre visible)</option>
        </select>
      </div>
      <label class="flex items-center gap-1.5">
        <input type="hidden" name="confirmar_antes" value="false" />
        <input type="checkbox" name="confirmar_antes" value="true" checked={@nodo["propiedades"]["confirmar_antes"] == true} class="accent-purple-600" />
        Confirmar antes de ejecutar
      </label>
      <div :if={@nodo["propiedades"]["confirmar_antes"] == true}>
        <label class="block text-gray-500 mb-0.5">Mensaje de confirmación</label>
        <input type="text" name="mensaje_confirmacion" value={@nodo["propiedades"]["mensaje_confirmacion"]}
          placeholder="¿Deseas aprobar?" class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
    </form>
    """
  end

  # Resumen/KPI -- tarjeta grande conectada a un valor REAL, reusando
  # Formula.evaluar/2 tal cual (mismo motor que Campo calculado). A
  # diferencia de Campo calculado no ofrece el constructor de chips
  # completo (SUM/condición/lookup a clic) -- se escribe la fórmula como
  # texto directo, mismo mini-lenguaje ({campo}, SUM(catalogo.campo), IF,
  # etc., ver moduledoc de Formula). Alcance reducido a propósito: es la
  # variante "grande y directa" para un solo número destacado, no un
  # reemplazo del editor completo.
  defp panel_propiedades(%{nodo: %{"tipo" => "resumen"}} = assigns) do
    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Etiqueta</label>
        <input type="text" name="etiqueta" value={@nodo["propiedades"]["etiqueta"]} placeholder="Ej. Ventas" class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Fórmula</label>
        <input type="text" name="formula" value={@nodo["propiedades"]["formula"]} placeholder="SUM(pty_ventas.monto)"
          class="w-full border border-gray-300 rounded px-2 py-1.5 font-mono" />
        <p class="text-gray-400 mt-1">
          Mismo lenguaje que Campo calculado: <span class="font-mono">{"{campo}"}</span>, <span class="font-mono">SUM(catalogo.campo)</span>,
          <span class="font-mono">COUNT(catalogo)</span>, <span class="font-mono">AVG</span>/<span class="font-mono">MIN</span>/<span class="font-mono">MAX</span>,
          operadores, <span class="font-mono">IF...THEN...ELSE</span>. Sin el armador de chips (ese solo está en Campo calculado).
        </p>
      </div>
      <div class="flex items-end gap-2">
        <div>
          <label class="block text-gray-500 mb-0.5">Formato</label>
          <select name="formato" class="border border-gray-300 rounded px-2 py-1.5">
            <option value="numero" selected={(@nodo["propiedades"]["formato"] || "numero") == "numero"}>Número</option>
            <option value="moneda" selected={@nodo["propiedades"]["formato"] == "moneda"}>Moneda</option>
            <option value="porcentaje" selected={@nodo["propiedades"]["formato"] == "porcentaje"}>Porcentaje</option>
          </select>
        </div>
        <div>
          <label class="block text-gray-500 mb-0.5">Decimales</label>
          <input type="number" name="decimales" min="0" max="10" value={@nodo["propiedades"]["decimales"]} class="w-24 border border-gray-300 rounded px-2 py-1.5" />
        </div>
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Ícono (emoji, opcional)</label>
        <input type="text" name="icono" value={@nodo["propiedades"]["icono"]} maxlength="4" class="w-20 border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <div>
        <label class="block text-gray-500 mb-0.5">Color</label>
        <select name="color" class="w-full border border-gray-300 rounded px-2 py-1.5">
          <option value="gris" selected={@nodo["propiedades"]["color"] == "gris"}>Gris</option>
          <option value="purpura" selected={(@nodo["propiedades"]["color"] || "purpura") == "purpura"}>Púrpura</option>
          <option value="azul" selected={@nodo["propiedades"]["color"] == "azul"}>Azul</option>
          <option value="verde" selected={@nodo["propiedades"]["color"] == "verde"}>Verde</option>
          <option value="amarillo" selected={@nodo["propiedades"]["color"] == "amarillo"}>Amarillo</option>
          <option value="rojo" selected={@nodo["propiedades"]["color"] == "rojo"}>Rojo</option>
        </select>
      </div>
    </form>
    """
  end

  # Timeline -- sin configuración de catálogo/campos: siempre muestra el
  # recorrido de ESTADOS de ESTE MISMO registro (mismo dato que la
  # pestaña "Historial", filtrado a transiciones), nunca de otro
  # catálogo. Ver FichaLive.nodo_plantilla_render/1 "timeline" -- se
  # resuelve solo, con @registro/@estados_por_id que ya viajan a
  # cualquier nodo, sin threading nuevo.
  defp panel_propiedades(%{nodo: %{"tipo" => "timeline"}} = assigns) do
    ~H"""
    <form phx-change="actualizar_propiedad" class="flex flex-col gap-2.5 text-xs">
      <div>
        <label class="block text-gray-500 mb-0.5">Título (opcional)</label>
        <input type="text" name="titulo" value={@nodo["propiedades"]["titulo"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </div>
      <p class="text-gray-400">Muestra automáticamente el recorrido de estados de este registro (las mismas transiciones que ya ves en la pestaña "Historial") — no hace falta elegir catálogo ni campos.</p>
    </form>
    """
  end

  # --- Componentes visuales compartidos (Fase 1 rediseño) -------------------
  # Reemplazan checkboxes/selects planos por toggles/swatches/botones de
  # ícono — el <form phx-change> que los envuelve sigue siendo el mismo de
  # siempre (mismo name/value por campo), esto solo cambia el widget.

  attr :name, :string, required: true
  attr :checked, :boolean, default: false
  attr :label, :string, default: nil

  defp toggle_switch(assigns) do
    ~H"""
    <label class="gc-toggle-row">
      <input type="hidden" name={@name} value="false" />
      <input type="checkbox" name={@name} value="true" checked={@checked} class="gc-toggle-input" />
      <span class="gc-toggle-track"></span>
      <span :if={@label} class="gc-toggle-label">{@label}</span>
    </label>
    """
  end

  attr :name, :string, required: true
  attr :valor, :string, default: nil
  attr :incluir_ninguno, :boolean, default: true

  defp swatch_picker(assigns) do
    ~H"""
    <div class="gc-swatch-row">
      <label :if={@incluir_ninguno} class={["gc-swatch gc-swatch-ninguno", @valor in [nil, ""] && "gc-swatch-on"]} title="Ninguno">
        <input type="radio" name={@name} value="" checked={@valor in [nil, ""]} class="sr-only" />
      </label>
      <label :for={{v, e} <- swatches()} class={["gc-swatch", @valor == v && "gc-swatch-on"]} style={"background:#{swatch_hex(v)}"} title={e}>
        <input type="radio" name={@name} value={v} checked={@valor == v} class="sr-only" />
      </label>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :valor, :string, default: "izquierda"

  defp botones_alineacion_h(assigns) do
    ~H"""
    <div class="gc-align-row">
      <label :for={{v, d} <- [{"izquierda", "M4 6h16M4 12h10M4 18h13"}, {"centro", "M4 6h16M8 12h8M6 18h12"}, {"derecha", "M4 6h16M10 12h10M7 18h13"}, {"justificado", "M4 6h16M4 12h16M4 18h16"}]}
        class={["gc-align-btn", (@valor || "izquierda") == v && "gc-align-on"]}>
        <input type="radio" name={@name} value={v} checked={(@valor || "izquierda") == v} class="sr-only" />
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d={d} /></svg>
      </label>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :valor, :string, default: "arriba"

  defp botones_alineacion_v(assigns) do
    ~H"""
    <div class="gc-align-row">
      <label :for={{v, titulo, d} <- [{"arriba", "Arriba", "M4 6h16M8 12h8M8 18h8"}, {"centro", "Centro", "M4 12h16M8 6h8M8 18h8"}, {"abajo", "Abajo", "M4 18h16M8 6h8M8 12h8"}, {"estirar", "Estirar", "M4 4h16v16H4z"}]}
        class={["gc-align-btn", (@valor || "arriba") == v && "gc-align-on"]} title={titulo}>
        <input type="radio" name={@name} value={v} checked={(@valor || "arriba") == v} class="sr-only" />
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d={d} /></svg>
      </label>
    </div>
    """
  end

  # --- Panel "Celda" (posición/tamaño/alineación/estilo/responsive) --------
  # Se antepone a panel_propiedades/1 SOLO mientras se edita un grid (ver
  # render/1) — ortogonal al tipo del nodo, por eso vive aparte en vez de
  # ser una cláusula más de panel_propiedades/1. Todo viaja junto por
  # "actualizar_celda" (ver celda_cambios_desde_params/4).
  attr :nodo, :map, required: true

  defp panel_celda(assigns) do
    celda = Map.merge(MetaPlantillas.celda_default(), assigns.nodo["propiedades"]["celda"] || %{})
    assigns = assigns |> assign(:celda, celda) |> assign(:estilo, celda["estilo"] || %{}) |> assign(:responsive, celda["responsive"] || %{})

    ~H"""
    <form phx-change="actualizar_celda" class="flex flex-col gap-3 text-xs pb-3 mb-3 border-b border-gray-100">
      <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400">Celda</div>

      <div class="grid grid-cols-2 gap-2">
        <div>
          <label class="block text-gray-500 mb-0.5">Fila</label>
          <input type="number" min="0" name="fila" value={@celda["fila"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
        </div>
        <div>
          <label class="block text-gray-500 mb-0.5">Columna</label>
          <input type="number" min="0" name="columna" value={@celda["columna"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
        </div>
        <div>
          <label class="block text-gray-500 mb-0.5">Colspan</label>
          <input type="number" min="1" name="colspan" value={@celda["colspan"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
        </div>
        <div>
          <label class="block text-gray-500 mb-0.5">Rowspan</label>
          <input type="number" min="1" name="rowspan" value={@celda["rowspan"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
        </div>
        <div>
          <label class="block text-gray-500 mb-0.5">Ancho</label>
          <input type="text" name="ancho" value={@celda["ancho"]} placeholder="auto" class="w-full border border-gray-300 rounded px-2 py-1.5" />
        </div>
        <div>
          <label class="block text-gray-500 mb-0.5">Alto</label>
          <input type="text" name="alto" value={@celda["alto"]} placeholder="auto" class="w-full border border-gray-300 rounded px-2 py-1.5" />
        </div>
      </div>

      <div class="grid grid-cols-2 gap-2">
        <div>
          <label class="block text-gray-500 mb-0.5">Alineación horizontal</label>
          <.botones_alineacion_h name="alineacion_h" valor={@celda["alineacion_h"]} />
        </div>
        <div>
          <label class="block text-gray-500 mb-0.5">Alineación vertical</label>
          <.botones_alineacion_v name="alineacion_v" valor={@celda["alineacion_v"]} />
        </div>
      </div>
      <p class="text-gray-400 -mt-2">Mueve el contenido DENTRO de la celda (que siempre llena su ancho) — para un ancho angosto de verdad, usá "Ancho" arriba.</p>

      <div>
        <label class="block text-gray-500 mb-1">Padding</label>
        <div class="gc-seg-row">
          <label :for={{v, e} <- [{"ninguno", "Ninguno"}, {"compacto", "Compacto"}, {"normal", "Normal"}, {"amplio", "Amplio"}]}
            class={["gc-seg-btn", (@celda["padding"] || "normal") == v && "gc-seg-on"]}>
            <input type="radio" name="padding" value={v} checked={(@celda["padding"] || "normal") == v} class="sr-only" />{e}
          </label>
        </div>
      </div>

      <.toggle_switch name="visible" checked={@celda["visible"] != false} label="Visible" />

      <div class="pt-2 border-t border-gray-100">
        <div class="text-gray-500 font-semibold mb-1.5">Estilo</div>
        <div class="grid grid-cols-1 gap-2.5">
          <div>
            <label class="block text-gray-500 mb-1">Fondo</label>
            <.swatch_picker name="estilo_fondo" valor={@estilo["fondo"]} />
          </div>
          <div>
            <label class="block text-gray-500 mb-1">Color de texto</label>
            <.swatch_picker name="estilo_color_texto" valor={@estilo["color_texto"]} />
          </div>
        </div>
        <div class="flex flex-wrap gap-4 mt-2.5">
          <.toggle_switch name="estilo_borde" checked={@estilo["borde"] == true} label="Borde" />
          <.toggle_switch name="estilo_redondeado" checked={@estilo["redondeado"] == true} label="Redondeado" />
          <.toggle_switch name="estilo_sombra" checked={@estilo["sombra"] == true} label="Sombra" />
        </div>
      </div>

      <div class="pt-2 border-t border-gray-100">
        <div class="text-gray-500 font-semibold mb-1.5">Responsive (móvil)</div>
        <.toggle_switch name="responsive_ocultar_movil" checked={@responsive["ocultar_movil"] == true} label="Ocultar en móvil" />
        <div class="grid grid-cols-3 gap-2 mt-2">
          <div>
            <label class="block text-gray-500 mb-0.5">Colspan móvil</label>
            <input type="number" min="1" name="responsive_colspan_movil" value={@responsive["colspan_movil"]} placeholder="—" class="w-full border border-gray-300 rounded px-2 py-1.5" />
          </div>
          <div>
            <label class="block text-gray-500 mb-0.5">Rowspan móvil</label>
            <input type="number" min="1" name="responsive_rowspan_movil" value={@responsive["rowspan_movil"]} placeholder="—" class="w-full border border-gray-300 rounded px-2 py-1.5" />
          </div>
          <div>
            <label class="block text-gray-500 mb-0.5">Orden móvil</label>
            <input type="number" name="responsive_orden_movil" value={@responsive["orden_movil"]} placeholder="—" class="w-full border border-gray-300 rounded px-2 py-1.5" />
          </div>
        </div>
      </div>
    </form>
    """
  end

  # Paleta corta de colores con nombre — ni un picker libre (fuera de
  # alcance) ni solo On/Off, un término medio manejable. Los mismos
  # nombres se resuelven a clases Tailwind reales del lado de FichaLive
  # (ver celda_classes/1 en ficha_live.ex) — un solo lugar de verdad
  # (esta lista) para no desincronizar los swatches de lo que existe.
  defp swatches, do: [{"gris", "Gris"}, {"purpura", "Púrpura"}, {"azul", "Azul"}, {"verde", "Verde"}, {"amarillo", "Amarillo"}, {"rojo", "Rojo"}]

  # Hex SOLO para pintar el swatch en el Constructor — FichaLive sigue
  # resolviendo el nombre a clases Tailwind por su cuenta (celda_classes/1),
  # este mapa no es la fuente de verdad de nada, es puramente decorativo acá.
  defp swatch_hex("gris"), do: "#9CA3AF"
  defp swatch_hex("purpura"), do: "#7C3AED"
  defp swatch_hex("azul"), do: "#3B82F6"
  defp swatch_hex("verde"), do: "#22C55E"
  defp swatch_hex("amarillo"), do: "#F5B92D"
  defp swatch_hex("rojo"), do: "#EF4444"
  defp swatch_hex(_), do: "#E5E7EB"

  # --- Lienzo del editor de grid (hoja de cálculo) --------------------------
  # Reemplaza al viejo botón fijo "‹ Volver al árbol" — ya no hay un único
  # "afuera", puede haber varios niveles (Raíz > Sección > Panel anidado).
  # Cada segmento navega directo a SU id con "entrar_contenedor" (ver
  # MetaPlantillas.ruta_hasta/2, que arma esta lista recorriendo el árbol
  # en cada render — nunca es estado propio de este LiveView).
  attr :ruta, :list, required: true

  defp breadcrumb(assigns) do
    assigns = assign(assigns, :ultimo, length(assigns.ruta) - 1)

    ~H"""
    <div class="flex items-center gap-1 flex-wrap text-xs">
      <%= for {seg, i} <- Enum.with_index(@ruta) do %>
        <button type="button" phx-click="entrar_contenedor" phx-value-id={seg.id || ""}
          class={[
            i == @ultimo && "font-bold text-gray-700 cursor-default",
            i != @ultimo && "text-gray-500 hover:text-purple-700 hover:underline"
          ]}>
          {seg.etiqueta}
        </button>
        <span :if={i < @ultimo} class="text-gray-300">›</span>
      <% end %>
    </div>
    """
  end

  attr :grid, :map, required: true
  attr :ruta, :list, required: true
  attr :nodo_seleccionado_id, :string, default: nil
  attr :celda_seleccionada, :map, default: nil
  attr :puede_deshacer, :boolean, default: false
  attr :puede_rehacer, :boolean, default: false
  attr :campos, :list, default: []
  attr :catalogos_disponibles, :list, default: []
  attr :catalogos_detalle_disponibles, :list, default: []

  defp grid_editor(%{grid: nil} = assigns) do
    ~H"""
    <div class="flex items-center gap-1 text-xs mb-3">
      <.breadcrumb ruta={@ruta} />
    </div>
    <p class="text-center text-gray-400 text-sm py-10">Este contenedor ya no existe (lo borraron desde otro lado).</p>
    """
  end

  defp grid_editor(assigns) do
    filas = assigns.grid["propiedades"]["filas"] || 1
    columnas = assigns.grid["propiedades"]["columnas"] || 1
    ocupadas = celdas_ocupadas(assigns.grid)
    seleccionado = assigns.nodo_seleccionado_id && Enum.find(assigns.grid["hijos"] || [], &(&1["id"] == assigns.nodo_seleccionado_id))
    combinado? = !!(seleccionado && (celda_de_nodo(seleccionado)["colspan"] > 1 or celda_de_nodo(seleccionado)["rowspan"] > 1))

    assigns =
      assigns
      |> assign(:filas, filas)
      |> assign(:columnas, columnas)
      |> assign(:celdas_vacias, celdas_vacias(filas, columnas, ocupadas))
      |> assign(:combinado?, combinado?)
      |> assign(:puede_combinar?, not is_nil(seleccionado) and not is_nil(assigns.celda_seleccionada))
      |> assign(
        :btn,
        "px-2 py-1 rounded-md border border-gray-200 text-gray-600 text-[11px] font-semibold hover:bg-gray-50 hover:border-gray-300 disabled:opacity-40 disabled:cursor-not-allowed disabled:hover:bg-transparent"
      )

    ~H"""
    <div>
      <div class="mb-2.5">
        <.breadcrumb ruta={@ruta} />
      </div>
      <div class="flex items-center flex-wrap gap-1.5 mb-3 pb-3 border-b border-gray-100">
        <button type="button" phx-click="grid_agregar_fila" phx-value-direccion="arriba" title="Agregar fila arriba" class={@btn}>Fila ↑</button>
        <button type="button" phx-click="grid_agregar_fila" phx-value-direccion="abajo" title="Agregar fila abajo" class={@btn}>Fila ↓</button>
        <button type="button" phx-click="grid_agregar_columna" phx-value-direccion="izquierda" title="Agregar columna a la izquierda" class={@btn}>Col ←</button>
        <button type="button" phx-click="grid_agregar_columna" phx-value-direccion="derecha" title="Agregar columna a la derecha" class={@btn}>Col →</button>
        <div class="w-px h-5 bg-gray-200 mx-1"></div>
        <button type="button" phx-click="grid_eliminar_fila" disabled={@filas <= 1} title="Eliminar fila" class={@btn}>Eliminar fila</button>
        <button type="button" phx-click="grid_eliminar_columna" disabled={@columnas <= 1} title="Eliminar columna" class={@btn}>Eliminar columna</button>
        <button type="button" phx-click="grid_duplicar_fila" title="Duplicar fila" class={@btn}>Duplicar fila</button>
        <button type="button" phx-click="agregar_campos_faltantes"
          title="Suma como filas nuevas SOLO los campos que todavía no estén en ningún lado de esta plantilla — no toca lo que ya armaste"
          class={@btn}>+ Campos faltantes</button>
        <div class="w-px h-5 bg-gray-200 mx-1"></div>
        <button type="button" phx-click="grid_combinar" disabled={!@puede_combinar?} title="Combinar celdas" class={@btn}>Combinar</button>
        <button type="button" phx-click="grid_separar" disabled={!@combinado?} title="Separar celda" class={@btn}>Separar</button>
        <button type="button" phx-click="grid_limpiar_celda" disabled={is_nil(@nodo_seleccionado_id)} title="Limpiar celda" class={@btn}>Limpiar celda</button>
        <div class="w-px h-5 bg-gray-200 mx-1"></div>
        <button type="button" phx-click="grid_deshacer" disabled={!@puede_deshacer} title="Deshacer" class={@btn}>↶ Deshacer</button>
        <button type="button" phx-click="grid_rehacer" disabled={!@puede_rehacer} title="Rehacer" class={@btn}>↷ Rehacer</button>
        <div class="w-px h-5 bg-gray-200 mx-1"></div>
        <div id="gc-zoom-controles" phx-hook="ZoomLienzo" data-target="gc-zoom-wrap" class="flex items-center gap-1">
          <button type="button" class="gc-zoom-btn" data-zoom-out title="Alejar">−</button>
          <span class="gc-zoom-label" data-zoom-label>100%</span>
          <button type="button" class="gc-zoom-btn" data-zoom-in title="Acercar">+</button>
          <button type="button" class={@btn} data-zoom-fit>Ajustar</button>
        </div>
        <button type="button" class={["toggle-cuadricula", @btn]} onclick="document.getElementById('gc-grid').classList.toggle('gc-cuadricula-on')">
          Cuadrícula
        </button>
        <button type="button" class={["toggle-reglas", @btn]} onclick="document.getElementById('gc-grid').classList.toggle('gc-reglas-on')">
          Reglas
        </button>
      </div>

      <div class="overflow-auto">
        <div id="gc-zoom-wrap" style="transform-origin: top left;">
        <div id="gc-grid" phx-hook="GridConstructor"
          class="inline-grid gc-editor"
          style={"grid-template-columns: 32px repeat(#{@columnas}, minmax(90px,1fr)); grid-template-rows: 24px repeat(#{@filas}, minmax(46px,auto));"}>
          <div class="gc-header" style="grid-column:1;grid-row:1"></div>

          <button :for={c <- 0..(@columnas - 1)} type="button" phx-click="seleccionar_celda" phx-value-fila="0" phx-value-columna={c}
            class="gc-header" style={"grid-column:#{c + 2};grid-row:1"}>{c + 1}</button>

          <button :for={f <- 0..(@filas - 1)} type="button" phx-click="seleccionar_celda" phx-value-fila={f} phx-value-columna="0"
            class="gc-header" style={"grid-column:1;grid-row:#{f + 2}"}>{f + 1}</button>

          <div :for={hijo <- @grid["hijos"] || []}
            style={celda_style(hijo)} draggable="true" data-origen="celda" data-nodo-id={hijo["id"]}
            data-fila={celda_de_nodo(hijo)["fila"]} data-columna={celda_de_nodo(hijo)["columna"]} data-ocupada="true"
            phx-click="seleccionar_nodo" phx-value-id={hijo["id"]}
            class={["gc-celda gc-ocupada", @nodo_seleccionado_id == hijo["id"] && "gc-celda-activa"]}>
            <.vista_documento_nodo nodo={hijo} campos={@campos} catalogos_disponibles={@catalogos_disponibles} catalogos_detalle_disponibles={@catalogos_detalle_disponibles} />
          </div>

          <div :for={{f, c} <- @celdas_vacias}
            style={"grid-column:#{c + 2};grid-row:#{f + 2}"} data-fila={f} data-columna={c} data-ocupada="false"
            phx-click="seleccionar_celda" phx-value-fila={f} phx-value-columna={c}
            class={["gc-celda gc-vacia", @celda_seleccionada == %{fila: f, columna: c} && "gc-celda-activa"]}>
            +
          </div>
        </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Vista "documento" de una celda ocupada (Fase 1 rediseño) --------------
  # Reemplaza al chip esquemático "Ícono + Tipo — etiqueta" de antes: cada
  # tipo se ve parecido a como va a salir realmente (tipografía/color), con
  # los campos de datos mostrando `{{campo}}` en vez de una etiqueta técnica
  # (no hay registro real en tiempo de diseño — el valor resuelto de verdad
  # solo existe en "Vista previa", que abre la Ficha real). Los contenedores
  # (sección/panel/pestañas/etc., sin contenido propio a este nivel — su
  # contenido vive un nivel más adentro, ver "Editar contenido →") se quedan
  # con el ícono + etiqueta de siempre, con mejor tipografía.
  attr :nodo, :map, required: true
  attr :campos, :list, default: []
  attr :catalogos_disponibles, :list, default: []
  attr :catalogos_detalle_disponibles, :list, default: []

  defp vista_documento_nodo(%{nodo: %{"tipo" => "campo"}} = assigns) do
    assigns = assign(assigns, :etiqueta, etiqueta_campo_por_nombre(assigns.campos, assigns.nodo["propiedades"]["campo"]))

    ~H"""
    <div class="gc-doc-campo">
      <div class="gc-doc-label">{@etiqueta}</div>
      <div class="gc-doc-var">{"{{#{@nodo["propiedades"]["campo"] || "campo"}}}"}</div>
    </div>
    """
  end

  defp vista_documento_nodo(%{nodo: %{"tipo" => "etiqueta"}} = assigns) do
    ~H"""
    <div class={"gc-doc-etiqueta gc-doc-estilo-#{@nodo["propiedades"]["estilo"] || "parrafo"}"}>
      <span :if={@nodo["propiedades"]["icono"] not in [nil, ""]}>{@nodo["propiedades"]["icono"]}</span>
      {@nodo["propiedades"]["texto"]}
    </div>
    """
  end

  defp vista_documento_nodo(%{nodo: %{"tipo" => "tarjeta"}} = assigns) do
    ~H"""
    <div class="gc-doc-tarjeta">
      <div class="gc-doc-tarjeta-titulo">
        <span :if={@nodo["propiedades"]["icono"] not in [nil, ""]}>{@nodo["propiedades"]["icono"]}</span>
        {@nodo["propiedades"]["titulo"]}
      </div>
      <div class="gc-doc-tarjeta-texto">{@nodo["propiedades"]["texto"]}</div>
    </div>
    """
  end

  defp vista_documento_nodo(%{nodo: %{"tipo" => "alerta"}} = assigns) do
    ~H"""
    <div class={"gc-doc-alerta gc-doc-nivel-#{@nodo["propiedades"]["nivel"] || "info"}"}>{@nodo["propiedades"]["texto"]}</div>
    """
  end

  defp vista_documento_nodo(%{nodo: %{"tipo" => "divisor"}} = assigns) do
    ~H"""
    <div class="gc-doc-divisor">
      <span :if={@nodo["propiedades"]["titulo"] not in [nil, ""]}>{@nodo["propiedades"]["titulo"]}</span>
    </div>
    """
  end

  defp vista_documento_nodo(%{nodo: %{"tipo" => "tabla"}} = assigns) do
    columnas =
      assigns.catalogos_disponibles
      |> campos_de_catalogo(assigns.nodo["propiedades"]["catalogo"])
      |> Enum.take(3)
      |> Enum.map(& &1.schema_context_properties["etiqueta"])

    assigns = assign(assigns, :columnas, columnas)

    ~H"""
    <div class="gc-doc-tabla">
      <div class="gc-doc-tabla-titulo">{@nodo["propiedades"]["titulo"]}</div>
      <div :if={@columnas != []} class="gc-doc-tabla-head">
        <span :for={c <- @columnas}>{c}</span>
      </div>
      <p :if={@columnas == []} class="gc-doc-hint">Elegí un catálogo relacionado →</p>
    </div>
    """
  end

  defp vista_documento_nodo(%{nodo: %{"tipo" => "renglones"}} = assigns) do
    detalle = Enum.find(assigns.catalogos_detalle_disponibles, &(&1.nombre == assigns.nodo["propiedades"]["catalogo"]))
    titulo = if assigns.nodo["propiedades"]["titulo"] not in [nil, ""], do: assigns.nodo["propiedades"]["titulo"], else: detalle && detalle.etiqueta
    columnas = if detalle, do: detalle.columnas_tabla |> Enum.take(3) |> Enum.map(& &1.schema_context_properties["etiqueta"]), else: []

    assigns = assigns |> assign(:titulo, titulo || "Renglones de detalle") |> assign(:columnas, columnas)

    ~H"""
    <div class="gc-doc-tabla">
      <div class="gc-doc-tabla-titulo">{@titulo}</div>
      <div :if={@columnas != []} class="gc-doc-tabla-head">
        <span :for={c <- @columnas}>{c}</span>
      </div>
      <p :if={@columnas == []} class="gc-doc-hint">Elegí un detalle →</p>
    </div>
    """
  end

  defp vista_documento_nodo(%{nodo: %{"tipo" => "campo_calculado"}} = assigns) do
    formula = (assigns.nodo["propiedades"]["formula"] || "") |> Formula.tokens_para_mostrar() |> Enum.map_join(" ", &texto_legible_token(&1, assigns.campos))
    assigns = assign(assigns, :formula, formula)

    ~H"""
    <div class="gc-doc-calculado">
      <div class="gc-doc-label">{@nodo["propiedades"]["etiqueta"]}</div>
      <div class="gc-doc-formula"><span class="gc-doc-fx">ƒx</span> {@formula}</div>
    </div>
    """
  end

  defp vista_documento_nodo(%{nodo: %{"tipo" => "boton"}} = assigns) do
    ~H"""
    <button type="button" disabled class={"gc-doc-boton gc-doc-boton-#{@nodo["propiedades"]["estilo"] || "primario"}"}>
      {@nodo["propiedades"]["etiqueta"]}
    </button>
    """
  end

  defp vista_documento_nodo(assigns) do
    ~H"""
    <div class="gc-doc-generico">
      <span class="text-gray-400 flex-shrink-0"><.icono tipo={icono_de_nodo(@nodo)} /></span>
      <span class="truncate">{etiqueta_nodo(@nodo)}</span>
    </div>
    """
  end

  defp etiqueta_campo_por_nombre(_campos, nil), do: "(sin elegir)"

  defp etiqueta_campo_por_nombre(campos, campo_field) do
    case Enum.find(campos, &(&1.schema_context_field == campo_field)) do
      nil -> campo_field
      c -> c.schema_context_properties["etiqueta"] || campo_field
    end
  end

  defp celdas_ocupadas(grid) do
    Enum.reduce(grid["hijos"] || [], MapSet.new(), fn hijo, acc ->
      celda = celda_de_nodo(hijo)

      Enum.reduce(celda["fila"]..(celda["fila"] + celda["rowspan"] - 1), acc, fn f, acc2 ->
        Enum.reduce(celda["columna"]..(celda["columna"] + celda["colspan"] - 1), acc2, fn c, acc3 -> MapSet.put(acc3, {f, c}) end)
      end)
    end)
  end

  defp celdas_vacias(filas, columnas, ocupadas) do
    for f <- 0..(filas - 1), c <- 0..(columnas - 1), not MapSet.member?(ocupadas, {f, c}), do: {f, c}
  end

  defp celda_style(hijo) do
    celda = celda_de_nodo(hijo)
    "grid-column:#{celda["columna"] + 2}/span #{celda["colspan"]};grid-row:#{celda["fila"] + 2}/span #{celda["rowspan"]}"
  end

  defp celda_de_nodo(nodo), do: Map.merge(MetaPlantillas.celda_default(), nodo["propiedades"]["celda"] || %{})

  # Campos VISIBLES del catálogo elegido en "Catálogo relacionado" — sale de
  # @catalogos_disponibles (ya calculado en mount/2 para el panel de
  # "Campo calculado", pero es la misma lista de TODOS los catálogos con sus
  # campos, sirve igual acá sin duplicar la query).
  defp campos_de_catalogo(_catalogos_disponibles, catalogo) when catalogo in [nil, ""], do: []

  defp campos_de_catalogo(catalogos_disponibles, catalogo) do
    case Enum.find(catalogos_disponibles, &(&1.nombre == catalogo)) do
      nil -> []
      c -> c.campos
    end
  end

  defp chip_class({:campo, _}), do: "inline-flex items-center gap-1 font-mono px-2 py-1 rounded-md bg-purple-100 text-purple-700 font-semibold"
  defp chip_class({:num, _}), do: "inline-flex items-center gap-1 font-mono px-2 py-1 rounded-md bg-green-100 text-green-700 font-semibold"
  defp chip_class({:op, _}), do: "inline-flex items-center gap-1 font-mono px-2 py-1 rounded-full bg-gray-200 text-gray-600 font-bold"
  defp chip_class({:agregado, _nombre, _arg}), do: "inline-flex items-center gap-1 font-mono px-2 py-1 rounded-md bg-indigo-100 text-indigo-700 font-semibold"
  defp chip_class({:str, _}), do: "inline-flex items-center gap-1 font-mono px-2 py-1 rounded-md bg-green-100 text-green-700 font-semibold"
  defp chip_class({:cmp, _}), do: "inline-flex items-center gap-1 font-mono px-2 py-1 rounded-full bg-gray-200 text-gray-600 font-bold"
  defp chip_class({:kw, _}), do: "inline-flex items-center gap-1 font-mono px-2 py-1 rounded-md bg-amber-100 text-amber-700 font-bold uppercase"
  defp chip_class(_token), do: "inline-flex items-center gap-1 font-mono px-1.5 py-1 rounded bg-gray-100 text-gray-500"

  defp texto_legible_token({:num, n}, _campos), do: numero_legible(n)

  @etiquetas_contexto %{"hoy" => "Hoy", "usuario_actual" => "Usuario actual", "empresa_activa" => "Empresa activa"}

  defp texto_legible_token({:campo, nombre}, campos) do
    case Enum.find(campos, &(&1.schema_context_field == nombre)) do
      nil -> Map.get(@etiquetas_contexto, nombre, nombre)
      c -> c.schema_context_properties["etiqueta"]
    end
  end

  defp texto_legible_token({:op, :+}, _campos), do: "+"
  defp texto_legible_token({:op, :-}, _campos), do: "−"
  defp texto_legible_token({:op, :*}, _campos), do: "×"
  defp texto_legible_token({:op, :/}, _campos), do: "÷"
  defp texto_legible_token({:lparen}, _campos), do: "("
  defp texto_legible_token({:rparen}, _campos), do: ")"
  defp texto_legible_token({:agregado, nombre, arg}, _campos), do: "#{nombre}(#{arg})"
  defp texto_legible_token({:str, s}, _campos), do: "\"#{s}\""
  defp texto_legible_token({:cmp, :gt}, _campos), do: ">"
  defp texto_legible_token({:cmp, :lt}, _campos), do: "<"
  defp texto_legible_token({:cmp, :gte}, _campos), do: "≥"
  defp texto_legible_token({:cmp, :lte}, _campos), do: "≤"
  defp texto_legible_token({:cmp, :eq}, _campos), do: "="
  defp texto_legible_token({:cmp, :neq}, _campos), do: "≠"
  defp texto_legible_token({:kw, :if}, _campos), do: "SI"
  defp texto_legible_token({:kw, :then}, _campos), do: "ENTONCES"
  defp texto_legible_token({:kw, :else}, _campos), do: "SI NO"

  # Inversa de texto_legible_token/2 — a partir del token "de verdad" (no
  # de la etiqueta bonita) arma de nuevo el pedacito de texto que
  # Formula.tokens_para_mostrar/1 tokenizaría igual, para reconstruir el
  # string completo al borrar un chip del medio.
  defp texto_de_token({:num, n}), do: numero_legible(n)
  defp texto_de_token({:campo, nombre}), do: "{#{nombre}}"
  defp texto_de_token({:op, :+}), do: "+"
  defp texto_de_token({:op, :-}), do: "-"
  defp texto_de_token({:op, :*}), do: "*"
  defp texto_de_token({:op, :/}), do: "/"
  defp texto_de_token({:lparen}), do: "("
  defp texto_de_token({:rparen}), do: ")"
  defp texto_de_token({:agregado, nombre, arg}), do: "#{nombre}(#{arg})"
  defp texto_de_token({:str, s}), do: "\"#{s}\""
  defp texto_de_token({:cmp, :gt}), do: ">"
  defp texto_de_token({:cmp, :lt}), do: "<"
  defp texto_de_token({:cmp, :gte}), do: ">="
  defp texto_de_token({:cmp, :lte}), do: "<="
  defp texto_de_token({:cmp, :eq}), do: "=="
  defp texto_de_token({:cmp, :neq}), do: "!="
  defp texto_de_token({:kw, :if}), do: "IF"
  defp texto_de_token({:kw, :then}), do: "THEN"
  defp texto_de_token({:kw, :else}), do: "ELSE"

  defp numero_legible(n) when n == trunc(n), do: Integer.to_string(trunc(n))
  defp numero_legible(n), do: to_string(n)

  defp campos_de(catalogos_disponibles, catalogo_nombre) do
    case Enum.find(catalogos_disponibles, &(&1.nombre == catalogo_nombre)) do
      nil -> []
      cat -> cat.campos
    end
  end

  # Etiquetas de los DEMÁS campo_calculado de la plantilla (nunca el que se
  # está editando — insertar "{EsteMismoCampo}" en su propia fórmula sería
  # una autorreferencia directa; FichaLive.resolver_calculado/4 la
  # detectaría igual como ciclo, pero no tiene sentido ofrecerla como
  # botón) — para citar el resultado de otro con "{Etiqueta}", igual que
  # cualquier campo real (ver FichaLive.valores_con_calculados/5, que es
  # quien realmente lo resuelve; acá solo se arma el chip).
  defp otros_campos_calculados(definicion, nodo_id) do
    definicion
    |> MetaPlantillas.nodos_de_tipo("campo_calculado")
    |> Enum.reject(&(&1["id"] == nodo_id))
    |> Enum.map(& &1["propiedades"]["etiqueta"])
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  # Tarjetas de "¿Qué querés agregar?" — "Resumen" y "Otro registro" dependen
  # de que exista al menos un catálogo relacionado (@catalogos_disponibles);
  # sin eso sus paneles no muestran nada, así que ni se ofrecen como tarjeta.
  # "Condición" no depende de catálogos relacionados y siempre se muestra.
  # "formula" SIEMPRE primero -- es la opción "Asistente" por defecto
  # (2026-08-14, pregunta inicial "¿Cómo querés obtener este valor?" en
  # panel_propiedades/1 de campo_calculado), las demás son las
  # herramientas que ya existían como "¿Qué querés agregar?".
  defp herramientas_calculado([]), do: [{"formula", "ƒ", "Fórmula / cálculo"}, {"condicion", "?", "Condición"}]

  defp herramientas_calculado(_catalogos_disponibles) do
    [
      {"formula", "ƒ", "Fórmula / cálculo"},
      {"condicion", "?", "Condición"},
      {"resumen", "Σ", "Resumen"},
      {"lookup", "🔗", "Otro registro"}
    ]
  end

  # Contra el registro de muestra de ESTE catálogo (el mismo que usa el
  # link "Vista previa" del header) — así quien arma el Autocompletar ve
  # el resultado real sin salir del Constructor ni publicar nada todavía.
  defp vista_previa_autocompletar(_nombre, nil, _campo_ref, _catalogo, _campos_destino, _campos_del_destino),
    do: {:error, :sin_registro_de_muestra}

  defp vista_previa_autocompletar(_nombre, _id, campo_ref, _catalogo, _campos_destino, _campos_del_destino)
       when campo_ref in [nil, ""],
       do: {:error, :incompleto}

  defp vista_previa_autocompletar(_nombre, _id, _campo_ref, catalogo, _campos_destino, _campos_del_destino)
       when catalogo in [nil, ""],
       do: {:error, :incompleto}

  defp vista_previa_autocompletar(_nombre, _id, _campo_ref, _catalogo, [], _campos_del_destino), do: {:error, :incompleto}

  defp vista_previa_autocompletar(nombre, registro_muestra_id, campo_ref, catalogo, campos_destino, campos_del_destino) do
    # :sistema en ambos obtener! (Fase 4a) -- herramienta de Constructor
    # (vista previa contra el registro de muestra), no un listado real para
    # un usuario final.
    with modulo_local when not is_nil(modulo_local) <- MetaSchemaContext.modulo_por_nombre(nombre),
         registro_local <- CatalogoGenerico.obtener!(modulo_local, :sistema, registro_muestra_id),
         id_valor when not is_nil(id_valor) <- Map.get(registro_local, String.to_existing_atom(campo_ref)),
         id_entero when not is_nil(id_entero) <- a_entero(id_valor),
         modulo_destino when not is_nil(modulo_destino) <- MetaSchemaContext.modulo_por_nombre(catalogo) do
      registro_destino = CatalogoGenerico.obtener!(modulo_destino, :sistema, id_entero)

      filas =
        Enum.map(campos_destino, fn campo ->
          c = Enum.find(campos_del_destino, &(&1.schema_context_field == campo))
          etiqueta = (c && c.schema_context_properties["etiqueta"]) || campo
          valor = Map.get(registro_destino, String.to_existing_atom(campo))
          {etiqueta, (valor not in [nil, ""] && valor) || "—"}
        end)

      {:ok, filas}
    else
      _ -> {:error, :sin_valor}
    end
  rescue
    _ -> {:error, :no_encontrado}
  end

  defp a_entero(n) when is_integer(n), do: n
  defp a_entero(%Decimal{} = d), do: Decimal.to_integer(d)

  defp a_entero(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp a_entero(_), do: nil

  defp mensaje_vista_previa({:error, :sin_registro_de_muestra}), do: "Este catálogo todavía no tiene registros para probar."
  defp mensaje_vista_previa({:error, :incompleto}), do: "Completá el paso 1 y elegí al menos un campo en el paso 2."
  defp mensaje_vista_previa({:error, :sin_valor}), do: "El registro de muestra no tiene un valor numérico en ese campo."
  defp mensaje_vista_previa({:error, :no_encontrado}), do: "No se encontró un registro con ese id en el catálogo destino."

  # Vista previa de "campo_calculado": a diferencia de la Ficha 360° real
  # (fail-open, cualquier error se ve como "—", ver Formula.formatear/2),
  # acá el objetivo es EXACTAMENTE lo contrario — mostrar qué salió mal
  # (mensaje_error_formula/1) para poder corregir la fórmula antes de
  # publicarla. Se evalúa contra el registro de muestra de ESTE catálogo
  # (el mismo que usa el link "Vista previa" del header) + el resultado de
  # los DEMÁS campo_calculado de @definicion (Formula.resolver_calculados/2,
  # la misma resolución de dependencias que usa la Ficha real) — así una
  # fórmula que referencia "{OtroCampo}" con el botón "∑" también se puede
  # probar acá, con las fórmulas tal como están en memoria ahora mismo
  # (incluyan o no cambios todavía sin guardar).
  defp vista_previa_calculado(_nombre, nil, _campos, _definicion, _nodo, _current_scope),
    do: {:error, :sin_registro_de_muestra}

  defp vista_previa_calculado(nombre, registro_muestra_id, campos, definicion, nodo, current_scope) do
    formula = nodo["propiedades"]["formula"] || ""

    with modulo when not is_nil(modulo) <- MetaSchemaContext.modulo_por_nombre(nombre) do
      # :sistema (Fase 4a) -- mismo criterio que vista_previa_autocompletar/6.
      registro = CatalogoGenerico.obtener!(modulo, :sistema, registro_muestra_id)
      valores_reales = Map.new(campos, &{&1.schema_context_field, Map.get(registro, String.to_existing_atom(&1.schema_context_field))})
      base = Map.merge(contexto_actual(current_scope), valores_reales)
      valores = Formula.resolver_calculados(definicion, base)
      Formula.evaluar(formula, valores)
    else
      _ -> {:error, :sin_registro_de_muestra}
    end
  rescue
    _ -> {:error, :sin_registro_de_muestra}
  end

  defp mensaje_error_formula({:error, :sin_registro_de_muestra}), do: "Este catálogo todavía no tiene registros para probar."
  defp mensaje_error_formula({:error, :formula_invalida}), do: "Fórmula vacía o inválida."
  defp mensaje_error_formula({:error, :tokens_sobrantes}), do: "Sobran caracteres al final de la fórmula."
  defp mensaje_error_formula({:error, :condicion_mal_formada}), do: "La condición SI/ENTONCES/SI NO está incompleta o mal armada."
  defp mensaje_error_formula({:error, :division_por_cero}), do: "División por cero."
  defp mensaje_error_formula({:error, :parentesis_sin_cerrar}), do: "Falta cerrar un paréntesis."
  defp mensaje_error_formula({:error, :llave_sin_cerrar}), do: "Falta cerrar una llave { }."
  defp mensaje_error_formula({:error, :comilla_sin_cerrar}), do: "Falta cerrar una comilla."
  defp mensaje_error_formula({:error, :expresion_incompleta}), do: "La fórmula quedó incompleta."
  defp mensaje_error_formula({:error, :token_inesperado}), do: "Hay un carácter o símbolo fuera de lugar."
  defp mensaje_error_formula({:error, {:campo_no_numerico, nombre}}), do: "\"#{nombre}\" no tiene un valor numérico en el registro de muestra."
  defp mensaje_error_formula({:error, {:campo_inexistente, catalogo, campo}}), do: "El catálogo \"#{catalogo}\" no tiene un campo \"#{campo}\"."
  defp mensaje_error_formula({:error, {:registro_no_encontrado, catalogo, id}}), do: "No se encontró el registro ##{id} en \"#{catalogo}\"."
  defp mensaje_error_formula({:error, {:catalogo_desconocido, catalogo}}), do: "No existe un catálogo \"#{catalogo}\"."
  defp mensaje_error_formula({:error, {:numero_invalido, texto}}), do: "\"#{texto}\" no es un número válido."
  defp mensaje_error_formula({:error, {:caracter_invalido, c}}), do: "Carácter no permitido: \"#{c}\"."
  defp mensaje_error_formula({:error, {:funcion_sin_parentesis, nombre}}), do: "A #{nombre} le falta \"(...)\"."
  defp mensaje_error_formula({:error, {:funcion_desconocida, nombre}}), do: "\"#{nombre}\" no es una función reconocida — usá SUM/COUNT/AVG/MIN/MAX."
  defp mensaje_error_formula({:error, {:argumento_invalido, arg}}), do: "Argumento inválido: \"#{arg}\"."
  defp mensaje_error_formula({:error, motivo}), do: "No se pudo calcular (#{inspect(motivo)})."

  # Mismos pseudo-campos de "Contexto" que la Ficha 360° real (ver
  # FichaLive.contexto_actual/1) — duplicado a propósito, cada LiveView es
  # dueño de su propia función privada, la única pieza compartida entre
  # ambos es el evaluador (Formula).
  defp contexto_actual(%Scope{usuario: usuario, empresa_activa: empresa}) do
    %{
      "hoy" => Date.utc_today(),
      "usuario_actual" => (usuario && (usuario.alias || usuario.email)) || "",
      "empresa_activa" => (empresa && empresa.nombre) || ""
    }
  end

  defp contexto_actual(_sin_scope) do
    %{"hoy" => Date.utc_today(), "usuario_actual" => "", "empresa_activa" => ""}
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
            <%= if @condicion["campo"] != "__estado__" do %>
              <option value="mayor" selected={@condicion["operador"] == "mayor"}>es mayor que</option>
              <option value="menor" selected={@condicion["operador"] == "menor"}>es menor que</option>
              <option value="mayor_igual" selected={@condicion["operador"] == "mayor_igual"}>es mayor o igual que</option>
              <option value="menor_igual" selected={@condicion["operador"] == "menor_igual"}>es menor o igual que</option>
            <% end %>
          </select>

          <%= if @condicion["operador"] in ["igual", "distinto"] do %>
            <select :if={@condicion["campo"] == "__estado__"} name="valor" class="w-full border border-gray-300 rounded px-2 py-1.5">
              <option value="" selected={@condicion["valor"] in [nil, ""]}>Elegir estado…</option>
              <option :for={e <- @estados} value={e} selected={@condicion["valor"] == e}>{e}</option>
            </select>
            <input :if={@condicion["campo"] != "__estado__"} type="text" name="valor" value={@condicion["valor"]}
              placeholder="Valor a comparar" class="w-full border border-gray-300 rounded px-2 py-1.5" />
          <% end %>

          <input :if={@condicion["operador"] in ["mayor", "menor", "mayor_igual", "menor_igual"]}
            type="number" step="any" name="valor" value={@condicion["valor"]}
            placeholder="Número a comparar" class="w-full border border-gray-300 rounded px-2 py-1.5" />
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

  defp icono(%{tipo: "lista_rapida"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <line x1="8" y1="6" x2="21" y2="6" /><line x1="8" y1="12" x2="21" y2="12" /><line x1="8" y1="18" x2="21" y2="18" />
      <line x1="3" y1="6" x2="3.01" y2="6" /><line x1="3" y1="12" x2="3.01" y2="12" /><line x1="3" y1="18" x2="3.01" y2="18" />
    </svg>
    """
  end

  defp icono(%{tipo: "renglones"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 10h18" /><path d="M3 15h18" />
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

  defp icono(%{tipo: "grid"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="3" y="3" width="18" height="18" rx="2" /><line x1="3" y1="9" x2="21" y2="9" /><line x1="3" y1="15" x2="21" y2="15" /><line x1="9" y1="3" x2="9" y2="21" /><line x1="15" y1="3" x2="15" y2="21" />
    </svg>
    """
  end

  defp icono(%{tipo: "boton"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="3" y="7" width="18" height="10" rx="3" /><line x1="8" y1="12" x2="16" y2="12" />
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
  defp icono(%{tipo: "resumen"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <line x1="12" y1="20" x2="12" y2="10" /><line x1="18" y1="20" x2="18" y2="4" /><line x1="6" y1="20" x2="6" y2="16" />
    </svg>
    """
  end

  defp icono(%{tipo: "vista_previa"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="3" y="3" width="18" height="18" rx="2" /><circle cx="8.5" cy="8.5" r="1.5" /><path d="M21 15l-5-5L5 21" />
    </svg>
    """
  end

  defp icono(%{tipo: "timeline"} = assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="4" cy="12" r="1.5" /><circle cx="12" cy="12" r="1.5" /><circle cx="20" cy="12" r="1.5" />
      <line x1="5.5" y1="12" x2="10.5" y2="12" /><line x1="13.5" y1="12" x2="18.5" y2="12" />
    </svg>
    """
  end

  defp icono(assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M12 20h9" /><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" />
    </svg>
    """
  end
end
