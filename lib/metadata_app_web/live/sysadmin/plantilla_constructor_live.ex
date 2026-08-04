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

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_bc", "editar"}}

  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerico}
  alias MetadataApp.MetaPlantillas
  alias MetadataApp.MetaPlantillas.Formula
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

    {:noreply, socket |> assign(:definicion, definicion) |> assign(:nodo_seleccionado_id, nodo["id"]) |> reset_resumen() |> reset_lookup() |> assign(:herramienta_calculado, nil)}
  end

  def handle_event("agregar_campo", %{"filtro" => filtro}, socket) do
    nodo = MetaPlantillas.nuevo_nodo_campo(filtro)
    definicion = MetaPlantillas.insertar_nodo(socket.assigns.definicion, contenedor_seleccionado(socket), nodo)

    {:noreply, socket |> assign(:definicion, definicion) |> assign(:nodo_seleccionado_id, nodo["id"]) |> reset_resumen() |> reset_lookup() |> assign(:herramienta_calculado, nil)}
  end

  # El selector de "Resumen" (catálogo/función/campo) es estado transitorio
  # del panel, no de la definicion — se resetea cada vez que cambia el
  # nodo seleccionado para no arrastrar una elección de un campo_calculado
  # a otro sin querer.
  def handle_event("seleccionar_nodo", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:nodo_seleccionado_id, id) |> reset_resumen() |> reset_lookup() |> assign(:herramienta_calculado, nil)}
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
    <div class={if @embebido?, do: "", else: "p-6"}>
      <div class="flex items-center justify-between flex-wrap gap-2 mb-4">
        <div :if={!@embebido?}>
          <h1 class="text-xl font-bold text-gray-900">PostView — {@header.schema_context_label}</h1>
          <p class="text-xs text-gray-500 mt-0.5">Diseña el tab "Datos" de la Ficha 360° de este catálogo.</p>
        </div>
        <div :if={@embebido?}></div>
        <div class="flex items-center gap-2 flex-wrap">
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

      <div :if={@plantilla} class="grid grid-cols-1 lg:grid-cols-[180px_1fr_280px] gap-4">
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
          <.panel_propiedades :if={@nodo_seleccionado_id} nodo={MetaPlantillas.buscar_nodo(@definicion, @nodo_seleccionado_id)} campos={@campos} catalogos_relacionables={@catalogos_relacionables} catalogos_disponibles={@catalogos_disponibles}
            resumen_catalogo={@resumen_catalogo} resumen_funcion={@resumen_funcion} resumen_campo={@resumen_campo}
            lookup_catalogo={@lookup_catalogo} lookup_id={@lookup_id} lookup_campo={@lookup_campo} definicion={@definicion}
            herramienta_calculado={@herramienta_calculado}
            nombre={@nombre} registro_muestra_id={@registro_muestra_id} />
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

  # Constructor de chips — la fórmula sigue siendo el mismo string de
  # siempre (Formula.evaluar/2 no cambió), esto solo la arma por clicks en
  # vez de tipeándola. @formula_tokens sale del MISMO tokenizer que usa el
  # evaluador (Formula.tokens_para_mostrar/1), así que lo que se ve acá
  # nunca se desincroniza de lo que realmente se va a evaluar.
  defp panel_propiedades(%{nodo: %{"tipo" => "campo_calculado"}} = assigns) do
    formula_tokens = Formula.tokens_para_mostrar(assigns.nodo["propiedades"]["formula"] || "")
    assigns = assign(assigns, :formula_tokens, formula_tokens)

    ~H"""
    <div class="flex flex-col gap-2.5 text-xs">
      <form phx-change="actualizar_propiedad">
        <label class="block text-gray-500 mb-0.5">Etiqueta</label>
        <input type="text" name="etiqueta" value={@nodo["propiedades"]["etiqueta"]} class="w-full border border-gray-300 rounded px-2 py-1.5" />
      </form>

      <div>
        <label class="block text-gray-500 mb-1">Fórmula</label>

        <div class="flex flex-wrap items-center gap-1.5 min-h-[38px] border border-gray-300 rounded-lg px-2 py-1.5 bg-gray-50">
          <span :for={{token, i} <- Enum.with_index(@formula_tokens)} class={chip_class(token)}>
            {texto_legible_token(token, @campos)}
            <button type="button" phx-click="formula_quitar_token" phx-value-indice={i} class="opacity-50 hover:opacity-100">✕</button>
          </span>
          <span :if={@formula_tokens == []} class="text-gray-400">Vacío — agregá un campo o un operador abajo</span>
        </div>

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

        <div class="mt-2.5 pt-2.5 border-t border-gray-100">
          <p class="text-gray-500 font-semibold mb-1.5">¿Qué querés agregar?</p>
          <div class="grid grid-cols-3 gap-1.5">
            <button :for={{herramienta, simbolo, etiqueta} <- herramientas_calculado(@catalogos_disponibles)}
              type="button" phx-click="seleccionar_herramienta_calculado" phx-value-herramienta={herramienta}
              class={[
                "flex flex-col items-center gap-0.5 px-2 py-2.5 rounded-lg border text-center",
                @herramienta_calculado == herramienta && "border-purple-400 bg-purple-50 text-purple-700",
                @herramienta_calculado != herramienta && "border-gray-200 text-gray-500 hover:border-gray-300 hover:bg-gray-50"
              ]}>
              <span class="text-base font-bold">{simbolo}</span>
              <span class="text-[11px] font-semibold">{etiqueta}</span>
            </button>
          </div>
        </div>

        <div :if={@herramienta_calculado == "condicion"} class="mt-2.5 pt-2.5 border-t border-gray-100">
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

        <div :if={@herramienta_calculado == "resumen" and @catalogos_disponibles != []} class="mt-2.5 pt-2.5 border-t border-gray-100">
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

        <div :if={@herramienta_calculado == "lookup" and @catalogos_disponibles != []} class="mt-2.5 pt-2.5 border-t border-gray-100">
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

      <form phx-change="actualizar_propiedad" class="flex items-end gap-2">
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
      </form>
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
        <label class="block text-gray-500 mb-1">Campos a mostrar</label>
        <p :if={@campos_del_catalogo == []} class="text-gray-400">Elegí un catálogo relacionado arriba primero.</p>
        <input type="hidden" name="campos[]" value="" />
        <label :for={c <- @campos_del_catalogo} class="flex items-center gap-1.5 mb-1">
          <input type="checkbox" name="campos[]" value={c.schema_context_field} checked={c.schema_context_field in @campos_actuales} class="accent-purple-600" />
          {c.schema_context_properties["etiqueta"]}
        </label>
        <p :if={@campos_del_catalogo != [] and @campos_actuales == []} class="text-gray-400 mt-1">Sin nada tildado, se muestra la descripción de siempre + el id.</p>
      </div>
    </form>
    """
  end

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
  defp herramientas_calculado([]), do: [{"condicion", "?", "Condición"}]

  defp herramientas_calculado(_catalogos_disponibles) do
    [{"condicion", "?", "Condición"}, {"resumen", "Σ", "Resumen"}, {"lookup", "🔗", "Otro registro"}]
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
    with modulo_local when not is_nil(modulo_local) <- MetaSchemaContext.modulo_por_nombre(nombre),
         registro_local <- CatalogoGenerico.obtener!(modulo_local, registro_muestra_id),
         id_valor when not is_nil(id_valor) <- Map.get(registro_local, String.to_existing_atom(campo_ref)),
         id_entero when not is_nil(id_entero) <- a_entero(id_valor),
         modulo_destino when not is_nil(modulo_destino) <- MetaSchemaContext.modulo_por_nombre(catalogo) do
      registro_destino = CatalogoGenerico.obtener!(modulo_destino, id_entero)

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
