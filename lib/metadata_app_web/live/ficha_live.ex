defmodule MetadataAppWeb.FichaLive do
  @moduledoc """
  Ficha 360°: vista de un registro puntual de CUALQUIER catálogo, reusable
  (no específica de "Marcas" ni de ningún catálogo en particular). Reglas del
  patrón, todas ya resueltas por el motor existente — acá solo se componen:

  - Qué se puede CONSULTAR: todos los campos visibles del catálogo
    (`MetaSchemaContext.listar_detalles/1`), como ya hace `CatalogoLive` para
    la tabla.
  - Qué se puede MODIFICAR: exclusivamente `MetaStateEngine.campos_editables/2`
    para la transición "guardar" resuelta (`MetaStateEngine.transicion_guardar/2`)
    en el estado actual — el drawer de edición nunca muestra un campo fuera
    de esa lista.
  - El guardado siempre pasa por `CatalogoGenerico.actualizar/2`, que ya
    rechaza en el changeset cualquier campo no editable (defensa real, no
    solo de UI) y corre el ciclo PRE/POST de la transición si existe.

  Ningún cambio a `MetaStateEngine` ni `CatalogoGenerico` — esta LiveView
  solo llama a funciones públicas que ya existían y ya tenían tests.
  """

  use MetadataAppWeb, :live_view_admin

  require Logger

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}

  import Ecto.Query
  import MetadataAppWeb.CampoInputComponents, only: [campo_input: 1]

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.Scope
  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerico}
  alias MetadataApp.MetaStateEngine
  alias MetadataApp.Renglones
  alias MetadataApp.Permissions
  alias MetadataApp.MetaPlantillas
  alias MetadataApp.MetaPlantillas.Formula
  alias MetadataApp.MetaSchema.TransicionEvento
  alias MetadataApp.Integraciones
  alias MetadataAppWeb.AdminNav
  alias MetadataAppWeb.GridEditableComponents

  def mount(%{"tabla" => tabla, "id" => id} = params, _session, socket) do
    socket =
      socket
      |> assign(:sidebar_open, false)
      # get_connect_info/2 solo existe durante mount/3 (roadmap #6) -- se
      # calcula acá y se guarda en assigns para reusarlo en guardar_alta/
      # guardar_cambios (que corren desde handle_event).
      |> assign(:contexto_auditoria, MetadataAppWeb.AuditoriaContexto.desde_socket(socket))

    case MetaSchemaContext.modulo_por_nombre(tabla) do
      nil ->
        {:ok, socket |> assign(:current_page, tabla) |> assign(:encontrado?, false)}

      schema_mod ->
        header = MetaSchemaContext.obtener_header_por_nombre(tabla)
        registro = CatalogoGenerico.obtener!(schema_mod, socket.assigns[:current_scope], id)

        {:ok,
         socket
         |> assign(:current_page, tabla)
         |> assign(:encontrado?, true)
         |> assign(:modo, :ver)
         |> assign(:tabla, tabla)
         |> assign(:schema_mod, schema_mod)
         |> assign(:header, header)
         |> assign(:es_detalle?, not is_nil(header.schema_encabezado_id))
         # ?plantilla_id=N — "Vista previa" del Constructor: fuerza una
         # plantilla puntual (publicada o no) en vez de la publicada real,
         # así se puede ver un borrador contra un registro de verdad sin
         # publicarlo. nil (el caso normal, sin query param) = comportamiento
         # de siempre.
         |> assign(:plantilla_preview_id, Map.get(params, "plantilla_id"))
         |> assign(:tab, "datos")
         |> assign(:form_values, %{})
         |> assign(:errores_campos, %{})
         |> assign(:error_guardado, nil)
         |> assign(:accion_externa_en_curso, nil)
         |> assign(:resultado_accion_externa, nil)
         |> cargar_registro(registro)}
    end
  end

  # Alta — mismo LiveView y misma plantilla que la Ficha 360° normal, pero
  # sin registro todavía: "@registro" es un mapa vacío (Map.get de cualquier
  # campo da nil, exactamente el valor que campo_input/1 ya sabe mostrar
  # vacío) así campo_row/1, nodo_plantilla_render/1, etc. se reusan tal cual,
  # sin un branch por tipo de nodo. Los campos editables salen de la
  # transición "alta" (no "guardar") — mismo criterio que ya usa
  # CatalogoLive.campos_alta para el botón "+ Nuevo registro" de siempre.
  def mount(%{"tabla" => tabla} = params, _session, socket) do
    socket =
      socket
      |> assign(:sidebar_open, false)
      |> assign(:contexto_auditoria, MetadataAppWeb.AuditoriaContexto.desde_socket(socket))

    case MetaSchemaContext.modulo_por_nombre(tabla) do
      nil ->
        {:ok, socket |> assign(:current_page, tabla) |> assign(:encontrado?, false)}

      schema_mod ->
        header = MetaSchemaContext.obtener_header_por_nombre(tabla)
        es_detalle? = not is_nil(header.schema_encabezado_id)

        columnas =
          tabla
          |> MetaSchemaContext.listar_detalles()
          |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
          |> Enum.filter(&get_in(&1, [:schema_context_properties, "visible"]))
          |> Enum.sort_by(&get_in(&1, [:schema_context_properties, "orden"]))
          |> Enum.map(&Map.put(&1, :opciones, opciones_para_columna(&1)))

        transicion_alta = if es_detalle?, do: nil, else: MetaStateEngine.transicion_alta(tabla)

        campos_editables =
          if es_detalle?,
            do: [],
            else: tabla |> MetaStateEngine.campos_editables(transicion_alta) |> campos_editables_propios(columnas)

        # ?plantilla_id=N — mismo criterio que el modo :ver (ver plantilla_a_mostrar/2):
        # "Vista previa" del Constructor apunta acá con un registro en blanco
        # (nunca hizo falta que el catálogo ya tuviera datos cargados para
        # poder juzgar el DISEÑO), forzando esa plantilla puntual (borrador
        # incluido) en vez de la publicada real.
        socket = assign(socket, :plantilla_preview_id, Map.get(params, "plantilla_id"))
        plantilla = plantilla_a_mostrar(socket, header.id)

        {:ok,
         socket
         |> assign(:current_page, tabla)
         |> assign(:encontrado?, true)
         |> assign(:modo, :alta)
         |> assign(:tabla, tabla)
         |> assign(:schema_mod, schema_mod)
         |> assign(:header, header)
         |> assign(:es_detalle?, es_detalle?)
         |> assign(:plantilla, plantilla)
         |> assign(:tab, "datos")
         |> assign(:registro, %{})
         |> assign(:columnas, columnas)
         |> assign(:estados_por_id, %{})
         |> assign(:mostrar_estado?, false)
         |> assign(:transicion_edicion, transicion_alta)
         |> assign(:campos_editables, campos_editables)
         |> assign(:detalle_campos_editables, [])
         |> assign(:otras_transiciones, [])
         |> assign(:relaciones, [])
         |> assign(:relaciones_total, 0)
         |> assign(:historial, [])
         |> assign(:form_values, %{})
         |> assign(:errores_campos, %{})
         |> assign(:error_guardado, nil)
         # Sin registro todavía (modo alta) no hay contra qué resolver
         # {campo} en una url_template -- los botones de Acciones externas
         # solo tienen sentido en modo :ver (ver header_acciones_externas/1).
         |> assign(:acciones_externas, [])
         |> assign(:accion_externa_en_curso, nil)
         |> assign(:resultado_accion_externa, nil)
         # Todavía no hay id de encabezado para listar renglones YA
         # persistidos, pero sí se puede dejar capturar renglones "al
         # vuelo" (R6, alta atómica: MetaStateEngine.dar_de_alta/5 acepta
         # crear encabezado + renglones iniciales en el mismo Multi) — se
         # acumulan en memoria en :detalle_renglones_nuevos y viajan como
         # `opciones[:renglones]` de CatalogoGenerico.crear/2 recién en
         # guardar_alta/2, nunca antes (no hay encabezado_id al que atarlos).
         |> assign(:catalogos_detalle, if(es_detalle?, do: [], else: cargar_catalogos_detalle(header.id)))
         |> assign(:detalle_renglones, %{})
         |> assign(:detalle_renglones_nuevos, %{})
         |> assign(:detalle_renglones_editados, %{})
         |> assign(:detalle_renglones_eliminados, %{})
         |> assign(:detalle_seleccion, %{})
         |> assign(:detalle_form_error, nil)}
    end
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, socket.assigns.current_page)
  end

  def handle_event("cambiar_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, tab)}
  end

  # No hay más modo edición separado — los campos editables ya se muestran
  # como input directo, siempre. "Cancelar" solo descarta lo tipeado
  # (vuelve a mostrar el valor real del registro en cada input).
  def handle_event("cancelar_edicion", _params, socket) do
    {:noreply,
     socket
     |> assign(:form_values, %{})
     |> assign(:errores_campos, %{})
     |> assign(:error_guardado, nil)}
  end

  def handle_event("validar", %{"campos" => campos_params}, socket) do
    cambios = campos_modificados(socket.assigns.registro, campos_params, socket.assigns.campos_editables)

    cambios =
      limpiar_descendientes_cambiados(
        socket.assigns.tabla,
        socket.assigns.columnas,
        socket.assigns.registro,
        socket.assigns.form_values,
        cambios
      )

    {:noreply, assign(socket, :form_values, cambios)}
  end

  # Ya no depende de que llegue un submit real del <form> de Datos (que
  # solo existe en el DOM cuando @tab == "datos") — usa @form_values,
  # mantenido en vivo por "validar" desde cualquier tab. Así el botón
  # "Guardar" de arriba funciona igual parado en Detalle, Relaciones o
  # Historial (necesario ahora que también manda los renglones nuevos en
  # staging, que se cargan justamente desde el tab Detalle).
  def handle_event("guardar", _params, socket) do
    case socket.assigns.modo do
      :alta -> guardar_alta(socket)
      :ver -> guardar_edicion(socket)
    end
  end

  # Cualquier transición del encabezado (baja/reactivar/lo que sea que el
  # catálogo tenga configurado, salvo "guardar" — ver guardar_cambios/6)
  # vuelve al listado en automático en vez de quedarse en la ficha —
  # pedido explícito del usuario. El flash sobrevive el push_navigate
  # (LiveView lo lleva a la próxima página), así el listado igual muestra
  # la confirmación.
  def handle_event("ejecutar_transicion", %{"accion" => accion}, socket) do
    contexto = Permissions.contexto_confiable(socket.assigns.current_scope)

    case MetaStateEngine.ejecutar_transicion(socket.assigns.registro, accion, contexto) do
      {:ok, _actualizado} ->
        {:noreply,
         socket
         |> put_flash(:info, "Transición ejecutada.")
         |> push_navigate(to: socket.assigns.header.schema_context_nav)}

      {:error, razon} ->
        {:noreply, assign(socket, :error_guardado, formatear_error(razon))}
    end
  end

  # Botón "Acciones externas" (Fase 6 de "Integraciones", 2026-08-07) —
  # dispara la llamada HTTP configurada vía start_async/3, NUNCA síncrono:
  # a diferencia de una regla post (dentro de la transacción, con timeout
  # corto, ver Integraciones.ejecutar/4), esto es un botón que un humano
  # clickea con el timeout default (15s) — bloquear el proceso de la
  # LiveView ese tiempo dejaría toda la pantalla congelada. Un solo
  # @accion_externa_en_curso (no por id): dos acciones a la vez sobre el
  # mismo registro no tiene un caso de uso real y complica innecesariamente
  # el manejo de errores parciales.
  def handle_event("ejecutar_accion_externa", %{"accion_id" => accion_id}, socket) do
    accion_id = String.to_integer(accion_id)
    %{registro: registro, header: header, current_scope: current_scope} = socket.assigns

    # Busca contra TODAS las acciones del catálogo (no solo
    # @acciones_externas, ya filtrada por permiso) para poder distinguir
    # "no existe" de "no tenés permiso" -- defensa en profundidad contra un
    # permiso revocado en OTRA pestaña/sesión mientras esta ficha seguía
    # abierta con la lista vieja en memoria, no el camino normal (el botón
    # ya no aparece si @acciones_externas no la incluye).
    accion = header.id |> Integraciones.listar_acciones() |> Enum.find(&(&1.id == accion_id))

    cond do
      is_nil(accion) ->
        {:noreply, socket}

      not Permissions.can?(current_scope, "ejecutar_#{accion.nombre}", header.schema_context_name) ->
        {:noreply, put_flash(socket, :error, "No tienes permiso para ejecutar esta acción.")}

      true ->
        {:noreply,
         socket
         |> assign(:accion_externa_en_curso, accion_id)
         |> assign(:resultado_accion_externa, nil)
         |> start_async(:accion_externa, fn -> {accion.nombre, Integraciones.ejecutar_accion(accion, registro, current_scope)} end)}
    end
  end

  def handle_event("cerrar_resultado_accion_externa", _params, socket) do
    {:noreply, assign(socket, :resultado_accion_externa, nil)}
  end

  # En modo alta no hay registro que releer — "Actualizar ficha" acá solo
  # limpia el error para que el usuario reintente el alta.
  def handle_event("actualizar_ficha", _params, %{assigns: %{modo: :alta}} = socket) do
    {:noreply, assign(socket, :error_guardado, nil)}
  end

  def handle_event("actualizar_ficha", _params, socket) do
    %{schema_mod: schema_mod, registro: registro} = socket.assigns
    registro_actual = CatalogoGenerico.obtener!(schema_mod, socket.assigns[:current_scope], registro.id)

    {:noreply,
     socket
     |> assign(:form_values, %{})
     |> assign(:errores_campos, %{})
     |> assign(:error_guardado, nil)
     |> cargar_registro(registro_actual)}
  end

  # --- Catálogo Maestro-Detalle: Grid Editable del tab "Detalle" ----------
  # Todo el estado interactivo de la tabla (teclado, pegado, validación en
  # vivo) vive en el hook JS GridEditable (assets/js/hooks/grid_editable.js)
  # — acá solo llegan 3 eventos, todos por lotes, nunca por tecla:
  #
  # - "grid_sync": el hook manda el estado completo de filas nuevas/editadas
  #   de un catálogo cada vez que hay una pausa al tipear, y siempre justo
  #   antes de que el botón "Guardar" del encabezado dispare "guardar" (ver
  #   el hook: intercepta ese click en fase de captura para sincronizar
  #   primero). Las filas nuevas se acumulan igual que antes
  #   (:detalle_renglones_nuevos); las editadas (renglones YA persistidos,
  #   con al menos un campo tocado) van a :detalle_renglones_editados, ya en
  #   la forma exacta que espera `opciones[:renglones]` de
  #   MetaStateEngine.ejecutar_transicion/4 (R4): una lista de mapas planos
  #   %{"renglon_id" => N, "<campo>" => valor}. Las eliminadas (renglones YA
  #   persistidos marcados con el botón "✕" del grid) van a
  #   :detalle_renglones_eliminados — soft-delete DIRECTO al guardar, sin
  #   transición (ver Renglones.eliminar_todos/3), nunca se mezclan con
  #   "editadas" aunque también tuvieran campos tocados.
  def handle_event("grid_sync", %{"catalogo" => catalogo, "nuevas" => nuevas, "editadas" => editadas, "eliminadas" => eliminadas}, socket) do
    items_editados = Enum.map(editadas, fn %{"renglon_id" => id, "campos" => campos} -> Map.put(campos, "renglon_id", id) end)

    {:noreply,
     socket
     |> assign(:detalle_renglones_nuevos, Map.put(socket.assigns.detalle_renglones_nuevos, catalogo, limpiar_renglones_vacios(nuevas)))
     |> assign(:detalle_renglones_editados, Map.put(socket.assigns.detalle_renglones_editados, catalogo, items_editados))
     |> assign(:detalle_renglones_eliminados, Map.put(socket.assigns.detalle_renglones_eliminados, catalogo, eliminadas))}
  end

  # - "grid_validar_fila": validación de servidor con debounce (lo que JS no
  #   puede resolver solo — existencia de FK, reglas del changeset) para UNA
  #   fila puntual, identificada por client_id (nunca se persiste acá, solo
  #   se arma el changeset para leer sus errores). Sin renglon_id: fila
  #   nueva, changeset "en blanco". Con renglon_id: fila existente, contra
  #   el registro real — "renglon_id" es el contador por maestro (R14), NO
  #   el id físico (bug real: `CatalogoGenerico.obtener!/2` busca por id y
  #   tronaba con NoResultsError apenas los números no coincidían por
  #   casualidad) — el lookup correcto es por encabezado_id + renglon_id
  #   juntos, mismo criterio que ya usa MetaStateEngine.buscar_renglones/5.
  def handle_event("grid_validar_fila", %{"catalogo" => catalogo, "client_id" => client_id, "campos" => campos} = params, socket) do
    detalle_modulo = MetaSchemaContext.modulo_por_nombre(catalogo)

    changeset =
      case Map.get(params, "renglon_id") do
        nil ->
          detalle_modulo.changeset(struct(detalle_modulo), campos)

        renglon_id ->
          # Gap conocido (Fase 5, no corregido acá) -- acotado a
          # socket.assigns.registro.id (el maestro, ya scope-checked al
          # montar la ficha), sin chequeo propio del catálogo DETALLE si
          # activara su propio alcance_habilitado. Mismo límite ya
          # documentado en MetaStateEngine.buscar_renglones/5.
          # credo:disable-for-next-line MetadataApp.CredoChecks.RepoDirectoConVariable
          case Repo.get_by(detalle_modulo, encabezado_id: socket.assigns.registro.id, renglon_id: renglon_id) do
            nil -> detalle_modulo.changeset(struct(detalle_modulo), campos)
            renglon -> detalle_modulo.changeset(renglon, campos)
          end
      end

    errores =
      changeset
      |> MetadataApp.MetaErrores.traducir()
      |> Map.new(fn {campo, mensajes} -> {Atom.to_string(campo), mensajes} end)

    {:noreply, push_event(socket, "grid_errores_fila", %{catalogo: catalogo, client_id: client_id, errores: errores})}
  end

  # - "renglon_transicion": la única forma de "sacar"/mover un renglón YA
  #   persistido (R12 — nunca un DELETE real) — cada botón que ofrece la
  #   tabla para una fila existente es una transición REAL ya configurada
  #   para este catálogo (@otras_transiciones, la misma lista que ya arma
  #   los botones del encabezado), nunca una acción hardcodeada tipo
  #   "cancelar". Es la misma operación que ya hace
  #   CatalogoLive.detalle_modal (checkbox + botón de transición), acá
  #   aplicada a un solo renglón desde la tabla.
  def handle_event("renglon_transicion", %{"catalogo" => catalogo, "renglon_id" => renglon_id, "accion" => accion}, socket) do
    contexto = Permissions.contexto_confiable(socket.assigns.current_scope)

    case MetaStateEngine.ejecutar_transicion(socket.assigns.registro, accion, contexto, renglones: %{catalogo => [renglon_id]}) do
      {:ok, actualizado} ->
        socket = cargar_registro(socket, actualizado)

        # columnas_tabla (subset curado), no columnas (completo) — el hook
        # JS se montó con ese mismo subset (ver panel_detalle_catalogo/1),
        # así que grid_recargar tiene que reconstruir "values" con las
        # mismas columnas o quedan desalineadas con this.columns del hook.
        columnas =
          socket.assigns.catalogos_detalle
          |> Enum.find(%{columnas_tabla: []}, &(&1.nombre == catalogo))
          |> Map.get(:columnas_tabla)

        filas = Map.get(socket.assigns.detalle_renglones, catalogo, [])

        {:noreply,
         push_event(socket, "grid_recargar", %{
           catalogo: catalogo,
           filas: GridEditableComponents.filas_para_js(filas, columnas, socket.assigns.estados_por_id),
           transiciones: Enum.map(socket.assigns.otras_transiciones, &Map.take(&1, [:accion, :etiqueta]))
         })}

      {:error, razon} ->
        {:noreply, assign(socket, :error_guardado, formatear_error(razon))}
    end
  end

  # --- Layout de 2 columnas del tab Detalle: formulario fijo (izq, 1/3) +
  # tabla (der, 2/3) — el formulario muestra/edita SIEMPRE el renglón
  # "seleccionado" en la tabla (@detalle_seleccion, por catálogo), nunca
  # un modal ni una fila expandida. El dueño de los DATOS de una fila
  # sigue siendo el hook JS (this.rows, igual que antes) — el formulario
  # es una vista alternativa de ESA misma fila, sincronizada en las dos
  # direcciones por push_event, reusando CampoInputComponents.campo_input/1
  # (con su picker de "referencia" ya construido) en vez de reinventar el
  # dispatch por tipo en JS.

  # El hook manda esto cada vez que la fila "activa" cambia (click,
  # flechas, Tab, foco programático) — nunca por tecla dentro de la MISMA
  # fila. `valores` son los que la tabla YA tiene en memoria para esa fila
  # (incluye tipeo sin sincronizar todavía), así el formulario arranca
  # siempre con el dato más fresco, no con lo último persistido.
  def handle_event(
        "detalle_seleccionar_fila",
        %{"catalogo" => catalogo, "client_id" => client_id, "valores" => valores} = params,
        socket
      ) do
    seleccion = %{client_id: client_id, renglon_id: Map.get(params, "renglon_id"), valores: valores}
    {:noreply, assign(socket, :detalle_seleccion, Map.put(socket.assigns.detalle_seleccion, catalogo, seleccion))}
  end

  # Edición en el formulario izquierdo — refleja de inmediato en la fila
  # correspondiente de la tabla (grid_actualizar_fila), que corre el mismo
  # camino de siempre ahí (setCelda/validación/sync debounced) como si el
  # usuario hubiese tipeado directo en la celda.
  def handle_event("detalle_form_cambiar", %{"catalogo" => catalogo, "renglon" => campos}, socket) do
    case Map.get(socket.assigns.detalle_seleccion, catalogo) do
      nil ->
        {:noreply, socket}

      seleccion ->
        valores_previos = seleccion.valores
        valores_merged = Map.merge(valores_previos, campos)
        columnas = columnas_de_catalogo(socket.assigns.catalogos_detalle, catalogo)

        # limpiar_descendientes_cambiados/5 espera un "registro" struct de
        # respaldo para cuando un campo no está en el mapa "antes" — acá
        # @seleccion.valores YA es el mapa completo del renglón (no
        # sparse como @form_values del encabezado), así que ese respaldo
        # nunca se ejercita de verdad; %{} alcanza.
        valores_finales = limpiar_descendientes_cambiados(catalogo, columnas, %{}, valores_previos, valores_merged)
        nueva_seleccion = %{seleccion | valores: valores_finales}

        # Refleja en la celda de la grilla (solo lectura) tanto lo que el
        # usuario tocó a mano como cualquier descendiente que se vació
        # solo (Municipio/Localidad si cambió Estado) — no solo `campos`.
        valores_a_reflejar =
          for {campo, valor} <- valores_finales, Map.get(valores_previos, campo) != valor, into: %{}, do: {campo, valor}

        {:noreply,
         socket
         |> assign(:detalle_seleccion, Map.put(socket.assigns.detalle_seleccion, catalogo, nueva_seleccion))
         |> push_event("grid_actualizar_fila", %{catalogo: catalogo, client_id: seleccion.client_id, valores: valores_a_reflejar})}
    end
  end

  # Limpia el formulario y le pide a la tabla una fila nueva en blanco —
  # la tabla la crea, la enfoca (arranca a escribir de una) y reporta su
  # client_id real vía "detalle_seleccionar_fila", cerrando el círculo.
  # También es el destino de "confirmar línea" (Enter en el último campo,
  # ver hook RenglonForm) — mismo resultado final que arrancar una línea
  # nueva a mano, por eso reusa el mismo evento en vez de duplicar lógica.
  # "detalle_enfocar_primero" es la señal explícita para que el hook del
  # formulario devuelva el foco al primer campo — no se puede inferir de
  # un `updated()` genérico sin arriesgar robarle el foco al usuario
  # mientras todavía está tipeando otra cosa.
  def handle_event("detalle_nueva_linea", %{"catalogo" => catalogo}, socket) do
    seleccion = %{client_id: nil, renglon_id: nil, valores: %{}}

    {:noreply,
     socket
     |> assign(:detalle_seleccion, Map.put(socket.assigns.detalle_seleccion, catalogo, seleccion))
     |> push_event("grid_nueva_fila", %{catalogo: catalogo})
     |> push_event("detalle_enfocar_primero", %{catalogo: catalogo})}
  end

  # Esc (ver hook RenglonForm) — "cancela la edición", no es lo mismo que
  # "detalle_eliminar_linea": una línea NUEVA sin persistir se descarta
  # entera (nunca llegó a existir, nada que revertir) y arranca una en
  # blanco de nuevo; un renglón YA PERSISTIDO conserva su lugar, solo
  # revierte los campos tocados a sus valores originales (grid_revertir_fila
  # limpia dirty/errors del lado del hook, así una edición cancelada no
  # queda igual "sucia" para grid_sync).
  def handle_event("detalle_cancelar_linea", %{"catalogo" => catalogo}, socket) do
    case Map.get(socket.assigns.detalle_seleccion, catalogo) do
      %{renglon_id: nil, client_id: client_id} when not is_nil(client_id) ->
        seleccion = %{client_id: nil, renglon_id: nil, valores: %{}}

        {:noreply,
         socket
         |> assign(:detalle_seleccion, Map.put(socket.assigns.detalle_seleccion, catalogo, seleccion))
         |> push_event("grid_quitar_fila", %{catalogo: catalogo, client_id: client_id})
         |> push_event("grid_nueva_fila", %{catalogo: catalogo})
         |> push_event("detalle_enfocar_primero", %{catalogo: catalogo})}

      %{renglon_id: renglon_id} when not is_nil(renglon_id) ->
        filas = Map.get(socket.assigns.detalle_renglones, catalogo, [])
        columnas = columnas_de_catalogo(socket.assigns.catalogos_detalle, catalogo)

        case Enum.find(filas, &(&1.renglon_id == renglon_id)) do
          nil ->
            {:noreply, socket}

          fila ->
            seleccion = %{client_id: nil, renglon_id: renglon_id, valores: valores_como_texto(fila, columnas)}

            {:noreply,
             socket
             |> assign(:detalle_seleccion, Map.put(socket.assigns.detalle_seleccion, catalogo, seleccion))
             |> push_event("grid_revertir_fila", %{catalogo: catalogo, renglon_id: renglon_id})
             |> push_event("detalle_enfocar_primero", %{catalogo: catalogo})}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Fila TODAVÍA no persistida: se saca del array entero (nunca llegó a
  # existir en la base) — "grid_quitar_fila". Renglón YA PERSISTIDO: un
  # renglón no tiene estado propio (R3 — el estado_id que tiene
  # físicamente es un espejo del maestro, nunca evoluciona solo), así que
  # "eliminarlo" no es una transición — es un soft-delete DIRECTO al
  # guardar (Renglones.eliminar_todos/3, ver guardar_cambios/8), disparado
  # acá solo como una MARCA visual/de staging ("grid_marcar_eliminar") —
  # el borrado real recién ocurre al hacer click en "Guardar".
  def handle_event("detalle_eliminar_linea", %{"catalogo" => catalogo}, socket) do
    case Map.get(socket.assigns.detalle_seleccion, catalogo) do
      %{renglon_id: nil, client_id: client_id} when not is_nil(client_id) ->
        {:noreply,
         socket
         |> assign(:detalle_seleccion, Map.delete(socket.assigns.detalle_seleccion, catalogo))
         |> push_event("grid_quitar_fila", %{catalogo: catalogo, client_id: client_id})}

      %{renglon_id: renglon_id} when not is_nil(renglon_id) ->
        {:noreply, push_event(socket, "grid_marcar_eliminar", %{catalogo: catalogo, renglon_id: renglon_id})}

      _ ->
        {:noreply, socket}
    end
  end

  # Prev/Next entre renglones YA persistidos (@detalle_renglones — los
  # todavía sin guardar solo existen en la tabla, no acá). Los valores del
  # formulario salen directo de ahí, sin ida y vuelta al hook — solo se le
  # pide que resalte/enfoque esa fila (grid_resaltar_fila), que de paso
  # confirma el client_id real al reportar la selección de nuevo.
  def handle_event("detalle_navegar", %{"catalogo" => catalogo, "direccion" => direccion}, socket) do
    filas = Map.get(socket.assigns.detalle_renglones, catalogo, [])
    columnas = columnas_de_catalogo(socket.assigns.catalogos_detalle, catalogo)
    actual_id = get_in(socket.assigns.detalle_seleccion, [catalogo, :renglon_id])

    case renglon_adyacente(filas, actual_id, direccion) do
      nil ->
        {:noreply, socket}

      fila ->
        seleccion = %{client_id: nil, renglon_id: fila.renglon_id, valores: valores_como_texto(fila, columnas)}

        {:noreply,
         socket
         |> assign(:detalle_seleccion, Map.put(socket.assigns.detalle_seleccion, catalogo, seleccion))
         |> push_event("grid_resaltar_fila", %{catalogo: catalogo, renglon_id: fila.renglon_id})}
    end
  end

  # Resultado del Task disparado por "ejecutar_accion_externa" (start_async/3,
  # ver ahí el motivo). {:exit, _} es un crash genuino dentro del Task —
  # sin esta cláusula el botón quedaría "en curso" para siempre si algo
  # revienta fuera del try/rescue que ya tiene Integraciones.ejecutar_accion/4.
  def handle_async(:accion_externa, {:ok, {nombre, {:ok, %{status: status, body: body}}}}, socket) do
    {:noreply,
     socket
     |> assign(:accion_externa_en_curso, nil)
     |> assign(:resultado_accion_externa, %{nombre: nombre, ok?: status in 200..299, status: status, body: body, error: nil})}
  end

  def handle_async(:accion_externa, {:ok, {nombre, {:error, motivo}}}, socket) do
    {:noreply,
     socket
     |> assign(:accion_externa_en_curso, nil)
     |> assign(:resultado_accion_externa, %{nombre: nombre, ok?: false, status: nil, body: nil, error: formatear_error_accion_externa(motivo)})}
  end

  def handle_async(:accion_externa, {:exit, razon}, socket) do
    {:noreply,
     socket
     |> assign(:accion_externa_en_curso, nil)
     |> assign(:resultado_accion_externa, %{nombre: nil, ok?: false, status: nil, body: nil, error: "Error inesperado: #{inspect(razon)}"})}
  end

  defp formatear_error_accion_externa(:timeout), do: "La API externa no respondió a tiempo."
  defp formatear_error_accion_externa({:conexion, motivo}), do: "No se pudo conectar: #{inspect(motivo)}"
  defp formatear_error_accion_externa({:excepcion, mensaje}), do: mensaje
  defp formatear_error_accion_externa(motivo), do: inspect(motivo)

  defp columnas_de_catalogo(catalogos_detalle, nombre) do
    catalogos_detalle |> Enum.find(%{columnas: []}, &(&1.nombre == nombre)) |> Map.get(:columnas)
  end

  defp valores_como_texto(fila, columnas) do
    Map.new(columnas, fn col ->
      {col.schema_context_field, to_string(Map.get(fila, String.to_existing_atom(col.schema_context_field)))}
    end)
  end

  defp renglon_adyacente([], _actual_id, _direccion), do: nil
  defp renglon_adyacente(filas, nil, _direccion), do: List.first(filas)

  defp renglon_adyacente(filas, actual_id, direccion) do
    idx = Enum.find_index(filas, &(&1.renglon_id == actual_id))
    delta = if direccion == "siguiente", do: 1, else: -1

    case idx do
      nil -> List.first(filas)
      i -> Enum.at(filas, i + delta)
    end
  end

  # No hay más botón separado "Guardar renglones nuevos" — el mismo
  # "Guardar" del encabezado (guardar_edicion/1) manda también los
  # renglones nuevos y editados en staging, todo en un solo clic.
  # @form_values ya es el diff contra el registro (mantenido en vivo por
  # "validar"). Los renglones EDITADOS (ya persistidos) solo se pueden
  # guardar si el catálogo tiene una transición "guardar" configurada —
  # R4 exige pasar por una transición del maestro, no hay otro camino.
  defp guardar_edicion(socket) do
    %{
      schema_mod: schema_mod,
      registro: registro,
      form_values: attrs,
      detalle_renglones_nuevos: renglones_nuevos_tabla,
      detalle_renglones_editados: renglones_editados_tabla,
      detalle_renglones_eliminados: renglones_eliminados_tabla,
      transicion_edicion: transicion_edicion
    } = socket.assigns

    renglones_nuevos = Map.new(renglones_nuevos_tabla, fn {catalogo, filas} -> {catalogo, limpiar_renglones_vacios(filas)} end)
    renglones_editados = Map.filter(renglones_editados_tabla, fn {_catalogo, filas} -> filas != [] end)
    renglones_eliminados = Map.filter(renglones_eliminados_tabla, fn {_catalogo, ids} -> ids != [] end)

    hay_renglones_nuevos? = Enum.any?(renglones_nuevos, fn {_catalogo, filas} -> filas != [] end)
    hay_renglones_editados? = map_size(renglones_editados) > 0
    hay_renglones_eliminados? = map_size(renglones_eliminados) > 0

    cond do
      map_size(attrs) == 0 and not hay_renglones_nuevos? and not hay_renglones_editados? and not hay_renglones_eliminados? ->
        {:noreply, socket}

      hay_renglones_editados? and is_nil(transicion_edicion) ->
        {:noreply,
         assign(
           socket,
           :error_guardado,
           "Este catálogo no tiene una transición \"guardar\" configurada — no se pueden editar renglones existentes sin pasar por una transición del encabezado."
         )}

      # Sin renglones EDITADOS, aplicar_encabezado/5 NUNCA pasa por
      # ejecutar_transicion/4 (cae a actualizar_si_hay_cambios, un simple
      # UPDATE sin ningún concepto de transición) — y crear_renglones_nuevos/3
      # ni Renglones.eliminar_todos/3 tampoco pasan por ahí. Sin este
      # chequeo, ni editar campos del encabezado ni insertar/eliminar
      # renglones exigía el permiso "guardar" del rol (encontrado real, dos
      # veces: primero con renglones nuevos, después renglones editados vía
      # "guardar" mostrando "Baja" disponible sin permiso — ver el fix de
      # contexto_confiable en ejecutar_transicion/renglon_transicion/
      # aplicar_encabezado). Cuando SÍ hay renglones editados, este chequeo
      # es redundante mansamente: ya lo hace verificar_permiso_transicion/3
      # dentro de ejecutar_transicion/4.
      (map_size(attrs) > 0 or hay_renglones_nuevos? or hay_renglones_eliminados?) and not hay_renglones_editados? and
          not Permissions.can?(socket.assigns.current_scope, "guardar", socket.assigns.header.schema_context_name) ->
        {:noreply,
         assign(socket, :error_guardado, "No tienes permiso para guardar cambios en este catálogo.")}

      registro_cambio_de_estado?(schema_mod, socket.assigns.current_scope, registro) ->
        {:noreply,
         assign(socket, :error_guardado, "El estado del registro cambió mientras estabas editando.")}

      true ->
        registro_actual = CatalogoGenerico.obtener!(schema_mod, socket.assigns.current_scope, registro.id)

        guardar_cambios(
          socket,
          registro_actual,
          attrs,
          renglones_nuevos,
          renglones_editados,
          renglones_eliminados,
          transicion_edicion,
          socket.assigns.current_scope
        )
    end
  end

  # @form_values ya es el diff de campos_modificados/3 contra el registro
  # (acá un mapa vacío, no hay registro todavía) — mantenido en vivo por
  # "validar" en cada tecleo, mismo mecanismo que :ver, sin volver a leer
  # el <form> directo.
  defp guardar_alta(socket) do
    %{
      schema_mod: schema_mod,
      header: header,
      form_values: attrs,
      detalle_renglones_nuevos: renglones_tabla
    } = socket.assigns

    # El hook GridEditable ya descarta filas vacías antes de sincronizar
    # (sincronizarAhora en grid_editable.js) — esto es la misma limpieza
    # defensiva del lado servidor, antes de mandarlo al motor.
    renglones = Map.new(renglones_tabla, fn {catalogo, filas} -> {catalogo, limpiar_renglones_vacios(filas)} end)

    case CatalogoGenerico.crear(schema_mod, socket.assigns.current_scope, attrs, renglones: renglones, contexto: socket.assigns.contexto_auditoria) do
      {:ok, _nuevo} ->
        {:noreply,
         socket
         |> put_flash(:info, "Registro creado.")
         |> push_navigate(to: header.schema_context_nav)}

      # El changeset puede ser del encabezado (schema_mod, error normal de
      # campo) o de UN renglón en staging (otro struct — R6 rechaza todo o
      # nada, ver ejecutar_nucleo_alta/4): solo el primer caso tiene sentido
      # mostrarlo campo por campo en @errores_campos, el segundo cae al
      # banner genérico de @error_guardado (mismo criterio que cualquier
      # otro error de renglón).
      {:error, %Ecto.Changeset{data: %struct{}} = changeset} when struct == schema_mod ->
        {:noreply, assign(socket, :errores_campos, MetadataApp.MetaErrores.traducir(changeset))}

      {:error, razon} ->
        {:noreply, assign(socket, :error_guardado, formatear_error(razon))}
    end
  end

  # Un solo clic, un solo resultado: el cambio de campos del encabezado
  # (junto con los renglones EDITADOS, si hay — R4, vía la transición
  # "guardar"), la creación de los renglones NUEVOS en staging, y el
  # soft-delete de los renglones ELIMINADOS viajan en la MISMA
  # Repo.transaction — todo o nada. Tanto crear como eliminar renglones
  # siguen sin pasar por MetaStateEngine.ejecutar_transicion/4 — esa
  # opción solo mueve/edita renglones que YA EXISTEN, no sabe crear ni
  # borrar ninguno (un renglón no tiene estado propio, R3, así que
  # "eliminarlo" no es una transición — ver Renglones.eliminar_todos/3).
  # Por eso las reglas PRE/POST de "guardar" ven los renglones EDITADOS
  # (van dentro de la misma transición), pero no los NUEVOS ni los
  # ELIMINADOS.
  #
  # contexto_auditoria (roadmap #6, ver AuditoriaContexto.desde_socket/1 en
  # mount/3) viaja a CatalogoGenerico.actualizar/3 y .crear_muchos/3 —
  # ejecutar_transicion/4 (R4, renglones editados) no lo necesita, ese
  # camino ya queda registrado por su propio TransicionEvento.
  defp guardar_cambios(socket, registro_actual, attrs, renglones_nuevos, renglones_editados, renglones_eliminados, transicion_edicion, current_scope) do
    contexto_auditoria = socket.assigns.contexto_auditoria
    catalogo_maestro = registro_actual.__struct__.__schema__(:source)

    resultado =
      Repo.transaction(fn ->
        with {:ok, actualizado} <-
               aplicar_encabezado(registro_actual, attrs, renglones_editados, transicion_edicion, contexto_auditoria, current_scope),
             {:ok, _creados} <- crear_renglones_nuevos(registro_actual.id, current_scope, renglones_nuevos, contexto_auditoria),
             {:ok, _eliminados} <- Renglones.eliminar_todos(catalogo_maestro, registro_actual.id, renglones_eliminados) do
          actualizado
        else
          {:error, motivo} -> Repo.rollback(motivo)
        end
      end)

    case resultado do
      # Vuelve al listado en automático en vez de quedarse en la ficha —
      # mismo criterio que "ejecutar_transicion" (pedido explícito del
      # usuario, para "guardar", "baja", "cancelar", cualquier transición).
      {:ok, actualizado} ->
        catalogos_tocados = Enum.uniq(Map.keys(renglones_nuevos) ++ Map.keys(renglones_editados))
        loguear_resumen_renglones(actualizado.id, socket.assigns.catalogos_detalle, catalogos_tocados)

        {:noreply,
         socket
         |> put_flash(:info, "Cambios guardados.")
         |> push_navigate(to: socket.assigns.header.schema_context_nav)}

      # Mismo criterio que guardar_alta/2: el changeset puede ser del
      # encabezado (error normal de campo) o de un renglón nuevo/editado —
      # solo el primero tiene sentido campo por campo en @errores_campos.
      {:error, %Ecto.Changeset{data: %struct{}} = changeset} when struct == registro_actual.__struct__ ->
        {:noreply, assign(socket, :errores_campos, MetadataApp.MetaErrores.traducir(changeset))}

      {:error, razon} ->
        {:noreply, assign(socket, :error_guardado, formatear_error(razon))}
    end
  end

  # Sin renglones editados: comportamiento de siempre (actualizar/2, que
  # además valida el "editable" del contrato — ver conversación previa).
  # Con renglones editados: tiene que pasar por la transición "guardar"
  # (R4) sí o sí, aunque @form_values venga vacío — es la única forma que
  # el motor conoce de tocar un campo de un renglón ya persistido.
  defp aplicar_encabezado(registro, attrs, renglones_editados, _transicion, contexto_auditoria, current_scope)
       when map_size(renglones_editados) == 0 do
    actualizar_si_hay_cambios(registro, current_scope, attrs, contexto_auditoria)
  end

  defp aplicar_encabezado(registro, attrs, renglones_editados, transicion, _contexto_auditoria, current_scope) do
    contexto = Map.merge(attrs, Permissions.contexto_confiable(current_scope))
    MetaStateEngine.ejecutar_transicion(registro, transicion.accion, contexto, renglones: renglones_editados)
  end

  defp actualizar_si_hay_cambios(registro, _scope, attrs, _contexto_auditoria) when map_size(attrs) == 0, do: {:ok, registro}

  defp actualizar_si_hay_cambios(registro, scope, attrs, contexto_auditoria),
    do: CatalogoGenerico.actualizar(registro, scope, attrs, contexto_auditoria)

  defp crear_renglones_nuevos(encabezado_id, scope, renglones, contexto_auditoria) do
    Enum.reduce_while(renglones, {:ok, []}, fn {catalogo, items}, {:ok, acc} ->
      case items do
        [] ->
          {:cont, {:ok, acc}}

        _ ->
          detalle_modulo = MetaSchemaContext.modulo_por_nombre(catalogo)
          attrs_items = Enum.map(items, &Map.put(&1, "encabezado_id", encabezado_id))

          case CatalogoGenerico.crear_muchos(detalle_modulo, scope, attrs_items, contexto_auditoria) do
            {:ok, creados} -> {:cont, {:ok, acc ++ creados}}
            {:error, _motivo} = error -> {:halt, error}
          end
      end
    end)
  end

  # Best-effort, no bloqueante: recalcula el resumen configurado (ver
  # MetadataApp.ResumenRenglones, MetadataAppWeb.GridEditableComponents)
  # de cada catálogo detalle recién tocado, contra lo que HAY en la base
  # después de "Guardar" — misma semántica de operación que el cliente ya
  # mostró en pantalla sin guardar (GridEditable.calcularResumen), pero
  # sobre los renglones reales. Solo para tener un lugar central de verdad
  # ante una futura discrepancia o un reporte/API que necesite lo mismo;
  # no afecta la respuesta al usuario ni el resultado del guardado.
  defp loguear_resumen_renglones(_registro_id, _catalogos_detalle, []), do: :ok

  defp loguear_resumen_renglones(registro_id, catalogos_detalle, catalogos_tocados) do
    Enum.each(catalogos_tocados, fn nombre ->
      with %{columnas: columnas} <- Enum.find(catalogos_detalle, &(&1.nombre == nombre)),
           true <- Enum.any?(columnas, &(get_in(&1.schema_context_properties, ["tipo"]) in ["integer", "decimal"])) do
        detalle_modulo = MetaSchemaContext.modulo_por_nombre(nombre)

        # :sistema -- best-effort de LOGGING interno (ver el comentario de
        # arriba: "no afecta la respuesta al usuario"), no una lista que se
        # le muestra a nadie.
        renglones =
          detalle_modulo
          |> CatalogoGenerico.listar(:sistema, %{"encabezado_id" => registro_id})
          |> Enum.map(&struct_a_mapa_resumen(&1, columnas))

        resumen = MetadataApp.ResumenRenglones.calcular(renglones, columnas)
        Logger.debug("Resumen de renglones (#{nombre}, encabezado ##{registro_id}): #{inspect(resumen)}")
      end
    end)
  rescue
    error -> Logger.warning("No se pudo recalcular el resumen de renglones tras guardar: #{inspect(error)}")
  end

  defp struct_a_mapa_resumen(struct, columnas) do
    Map.new(columnas, fn col -> {col.schema_context_field, Map.get(struct, String.to_existing_atom(col.schema_context_field))} end)
  end

  # Plug decodifica "renglones[0][x]=a&renglones[1][x]=b" como un MAPA con
  # claves "0"/"1" (no una lista) — se reordena acá una sola vez, en el
  # único lugar donde el phx-change de la tabla entra al server.
  # Una fila "vacía" es la fila en blanco que la tabla siempre deja al
  # final (nunca tipeada) o cualquier otra que el usuario vació de vuelta —
  # "false" cuenta como vacío acá porque es lo que manda un checkbox sin
  # marcar, no una respuesta real. El hook GridEditable ya filtra esto de
  # su lado (ver sincronizarAhora), esto es la misma limpieza defensiva del
  # lado servidor.
  defp limpiar_renglones_vacios(filas) do
    Enum.reject(filas, fn fila -> fila == %{} or Enum.all?(Map.values(fila), &(&1 in [nil, "", "false"])) end)
  end

  # Cuenta renglones nuevos + editados + eliminados en staging — usado
  # para el badge del tab "Detalle" y para habilitar el botón "Guardar".
  defp contar_cambios_detalle(renglones_nuevos, renglones_editados, renglones_eliminados) do
    nuevos = renglones_nuevos |> Map.values() |> Enum.map(&length(limpiar_renglones_vacios(&1))) |> Enum.sum()
    editados = renglones_editados |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    eliminados = renglones_eliminados |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    nuevos + editados + eliminados
  end

  # Chequeo de concurrencia best-effort a nivel de esta pantalla — el motor
  # no tiene optimistic lock (ningún catálogo generado tiene columna
  # `version`/`lock_version` hoy). Comparar el estado_id recién leído contra
  # el que tenía el registro cuando se cargó la ficha cubre el caso real más
  # común (otro usuario/regla movió el estado mientras este usuario editaba)
  # sin inventar una garantía transaccional que el esquema no tiene todavía.
  defp registro_cambio_de_estado?(schema_mod, scope, registro_cargado) do
    actual = CatalogoGenerico.obtener!(schema_mod, scope, registro_cargado.id)
    actual.estado_id != registro_cargado.estado_id
  end

  # Una transición de un catálogo Maestro-Detalle puede legítimamente
  # incluir en campos_editables campos de un catálogo DETALLE (para el
  # editor de "renglones" de BcMotorLive/la API con "renglones": ...) —
  # pero el form de esta Ficha 360° solo edita los campos PROPIOS del
  # maestro. Sin este filtro, campos_modificados/3 explotaba con
  # `String.to_existing_atom/1` al recibir un campo que nunca fue field
  # de ESTE schema (bug real, reportado en producción).
  defp campos_editables_propios(campos_editables, columnas) do
    propios = MapSet.new(columnas, & &1.schema_context_field)
    Enum.filter(campos_editables, &MapSet.member?(propios, &1))
  end

  # Un renglón nuevo (sin renglon_id todavía) siempre es editable — el alta
  # de renglones no pasa por ninguna transición, así que campos_editables no
  # le aplica (ver crear_renglones_nuevos/3). Un renglón YA PERSISTIDO solo
  # puede tocar los campos que la transición "guardar" resuelta whitelisteó
  # explícitamente (MetaStateEngine.campos_editables/2, SIN el filtro
  # campos_editables_propios/2 que usa el formulario del encabezado — acá sí
  # interesan los campos de catálogos detalle). Sin este chequeo el usuario
  # podía tipear libremente en un campo que el servidor iba a rechazar
  # recién al Guardar con "no editable en esta transición" (bug real,
  # reportado).
  defp campo_detalle_editable?(_campo, %{renglon_id: nil}, _campos_editables), do: true
  defp campo_detalle_editable?(_campo, nil, _campos_editables), do: true

  defp campo_detalle_editable?(campo, %{renglon_id: renglon_id}, campos_editables) when not is_nil(renglon_id) do
    campo.schema_context_field in campos_editables
  end

  defp campos_modificados(registro, campos_params, campos_editables) do
    Enum.reduce(campos_editables, %{}, fn campo, acc ->
      nuevo = Map.get(campos_params, campo)
      original = Map.get(registro, String.to_existing_atom(campo))

      if not is_nil(nuevo) and to_string(original) != nuevo do
        Map.put(acc, campo, nuevo)
      else
        acc
      end
    end)
  end

  # Combos en cascada: si alguno de los campos referencia con
  # descendientes (Estado, Municipio...) cambió de valor efectivo entre
  # `valores_antes` y `valores_despues`, vacía en `valores_despues` a
  # TODOS sus descendientes (directos e indirectos —
  # MetaSchemaContext.descendientes/2 ya resuelve la cadena completa) —
  # así Municipio/Localidad no quedan con un valor que dejó de ser válido
  # para el nuevo padre. Acotado a campos tipo "referencia" de `columnas`
  # (ya en memoria, sin query) para no pagar un `listar_detalles/1` por
  # CADA campo tocado en cada evento, solo por los que de verdad podrían
  # tener hijos.
  defp limpiar_descendientes_cambiados(catalogo, columnas, registro, valores_antes, valores_despues) do
    campos_referencia =
      columnas
      |> Enum.filter(&(&1.schema_context_properties["tipo"] == "referencia"))
      |> Enum.map(& &1.schema_context_field)
      |> MapSet.new()

    padres_cambiados =
      valores_despues
      |> Map.keys()
      |> Enum.filter(&MapSet.member?(campos_referencia, &1))
      |> Enum.filter(fn campo ->
        antes = Map.get(valores_antes, campo) || valor_registro_seguro(registro, campo)
        Map.get(valores_despues, campo) != antes
      end)

    Enum.reduce(padres_cambiados, valores_despues, &MetaSchemaContext.limpiar_descendientes(catalogo, &1, &2))
  end

  # Sin ?plantilla_id= (el caso normal): la publicada de siempre. Con el
  # query param (link "Vista previa" del Constructor): esa plantilla
  # puntual, publicada o no — si el id es inválido/fue borrado, cae de
  # nuevo a la publicada en vez de romper la página.
  defp plantilla_a_mostrar(socket, header_id) do
    case socket.assigns[:plantilla_preview_id] do
      nil -> MetaPlantillas.obtener_plantilla_publicada(header_id)
      id -> MetaPlantillas.obtener_plantilla!(id)
    end
  rescue
    Ecto.NoResultsError -> MetaPlantillas.obtener_plantilla_publicada(header_id)
  end

  defp cargar_registro(socket, registro) do
    %{tabla: tabla, header: header, es_detalle?: es_detalle?} = socket.assigns

    columnas =
      tabla
      |> MetaSchemaContext.listar_detalles()
      |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
      |> Enum.filter(&get_in(&1, [:schema_context_properties, "visible"]))
      |> Enum.sort_by(&get_in(&1, [:schema_context_properties, "orden"]))
      |> Enum.map(&Map.put(&1, :opciones, opciones_para_columna(&1)))

    estados_por_id = MetaStateEngine.mapa_nombres_estados(tabla)

    transicion_edicion =
      if es_detalle?, do: nil, else: MetaStateEngine.transicion_guardar(tabla, registro.estado_id)

    # Sin filtrar por campos_editables_propios/2 a propósito, a diferencia
    # de @campos_editables — esta versión completa (con campos de
    # catálogos detalle incluidos) es la que necesita
    # campo_detalle_editable?/3 para saber, campo por campo de un renglón
    # YA PERSISTIDO, si la transición "guardar" resuelta lo dejó tocar.
    detalle_campos_editables_raw =
      if es_detalle?, do: [], else: MetaStateEngine.campos_editables(tabla, transicion_edicion)

    campos_editables =
      if es_detalle?,
        do: [],
        else: campos_editables_propios(detalle_campos_editables_raw, columnas)

    # MetaStateEngine.transiciones_disponibles/2 asume estado_id no-nil
    # (transiciones_desde/2 hace `t.estado_origen_id == ^estado_id`, que Ecto
    # rechaza en tiempo de ejecución si estado_id es nil — bug preexistente,
    # nunca ejercitado porque todo caller hasta ahora asumía un registro con
    # estado ya asignado). Acá se evita el caso en vez de tocar el motor: sin
    # estado_id no hay "estado actual" desde el cual listar transiciones.
    otras_transiciones =
      if es_detalle? or is_nil(registro.estado_id) do
        []
      else
        contexto = Permissions.contexto_confiable(socket.assigns.current_scope)

        registro
        |> MetaStateEngine.transiciones_disponibles(contexto)
        |> Enum.reject(&(&1.accion == "guardar"))
      end

    relaciones = cargar_relaciones(socket.assigns[:current_scope], tabla, registro.id)

    # Catálogo Maestro-Detalle: mismo criterio que ya usa CatalogoLive
    # (catalogos_detalle + detalle_renglones) — antes solo se podía
    # agregar un renglón volviendo a la tabla y abriendo el modal viejo;
    # acá la Ficha 360° ya tiene el id real del maestro, así que se
    # resuelve en el lugar, sin ese viaje de ida y vuelta.
    catalogos_detalle = cargar_catalogos_detalle(header.id)
    detalle_renglones = cargar_detalle_renglones(socket.assigns[:current_scope], catalogos_detalle, registro.id, estados_por_id)

    socket
    |> assign(:registro, registro)
    |> assign(:plantilla, plantilla_a_mostrar(socket, header.id))
    |> assign(:columnas, columnas)
    |> assign(:estados_por_id, estados_por_id)
    |> assign(:mostrar_estado?, estados_por_id != %{})
    |> assign(:transicion_edicion, transicion_edicion)
    |> assign(:campos_editables, campos_editables)
    |> assign(:detalle_campos_editables, detalle_campos_editables_raw)
    |> assign(:otras_transiciones, otras_transiciones)
    |> assign(:relaciones, relaciones)
    |> assign(:relaciones_total, Enum.sum(Enum.map(relaciones, & &1.total)))
    |> assign(:historial, cargar_historial(header.id, registro.id, catalogos_detalle, detalle_renglones))
    |> assign(:catalogos_detalle, catalogos_detalle)
    |> assign(:detalle_renglones, detalle_renglones)
    |> assign(:detalle_renglones_nuevos, %{})
    |> assign(:detalle_renglones_editados, %{})
    |> assign(:detalle_renglones_eliminados, %{})
    |> assign(:detalle_seleccion, %{})
    |> assign(:detalle_form_error, nil)
    |> assign(:acciones_externas, acciones_externas_permitidas(socket, header))
  end

  # RBAC (Fase 7 de "Integraciones") — mismo criterio que
  # verificar_permiso_transicion/3 del motor de estados: deny-by-default,
  # el botón directamente no aparece si falta {recurso: catálogo, accion:
  # "ejecutar_<nombre>"} (ver Integraciones.registrar_permiso_ejecucion/1,
  # que la registra sola al crear/editar la acción).
  defp acciones_externas_permitidas(socket, header) do
    header.id
    |> Integraciones.listar_acciones()
    |> Enum.filter(&Permissions.can?(socket.assigns.current_scope, "ejecutar_#{&1.nombre}", header.schema_context_name))
  end

  defp cargar_catalogos_detalle(header_id) do
    header_id
    |> MetaSchemaContext.listar_catalogos_detalle()
    |> Enum.map(fn h ->
      columnas_detalle =
        h.schema_context_name
        |> MetaSchemaContext.listar_detalles()
        |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
        |> Enum.filter(&get_in(&1, [:schema_context_properties, "visible"]))
        |> Enum.sort_by(&get_in(&1, [:schema_context_properties, "orden"]))
        |> Enum.map(&Map.put(&1, :opciones, opciones_para_columna(&1)))

      # :columnas_tabla — subconjunto curado (BcMotorLive → Campos → "En
      # tabla") para catálogos con muchos campos, donde mostrar TODOS como
      # columna en la tabla ancha es inusable. :columnas (completo) sigue
      # siendo lo que usa el formulario de al lado (formulario_renglon/1) —
      # ahí sí entra cualquier campo visible, sin curar.
      columnas_tabla = Enum.filter(columnas_detalle, &MetaSchemaContext.mostrar_en_tabla?(&1.schema_context_properties))

      %{nombre: h.schema_context_name, etiqueta: h.schema_context_label, columnas: columnas_detalle, columnas_tabla: columnas_tabla}
    end)
  end

  defp cargar_detalle_renglones(scope, catalogos_detalle, encabezado_id, estados_por_id) do
    Map.new(catalogos_detalle, fn %{nombre: nombre} ->
      detalle_modulo = MetaSchemaContext.modulo_por_nombre(nombre)

      filas =
        detalle_modulo
        |> CatalogoGenerico.listar(scope, %{"encabezado_id" => encabezado_id})
        |> Enum.map(&CatalogoGenerico.serializar(&1, estados_por_id))

      {nombre, filas}
    end)
  end

  # Catálogos que dependen de este (campo tipo "referencia" apuntando acá) —
  # reusa MetaSchemaContext.listar_dependientes/1, que ya existe para
  # bloquear el borrado total de un catálogo. Convención del proyecto: un
  # par de catálogos tiene a lo sumo un campo de referencia entre sí (el
  # mensaje de validate en meta_schema/detail.ex ya lo asume) — si hubiera
  # más de uno, se usa el primero encontrado.
  defp cargar_relaciones(scope, tabla, id) do
    tabla
    |> MetaSchemaContext.listar_dependientes()
    |> Enum.map(&relacion_de(scope, &1, tabla, id))
    |> Enum.reject(&is_nil/1)
  end

  defp relacion_de(scope, dep_nombre, tabla, id) do
    campo_fk =
      dep_nombre
      |> MetaSchemaContext.listar_detalles()
      |> Enum.find(fn d ->
        props = d.schema_context_properties
        props["tipo"] == "referencia" and props["catalogo"] == tabla
      end)

    dep_mod = MetaSchemaContext.modulo_por_nombre(dep_nombre)
    dep_header = MetaSchemaContext.obtener_header_por_nombre(dep_nombre)

    if campo_fk && dep_mod && dep_header do
      filtro = %{campo_fk.schema_context_field => id}

      # "campos_relacion" (BcMotorLive → Relaciones → Configurar, sección
      # "Campos propios... que se muestran cuando aparece como
      # relacionado") — configurado A MANO por catálogo, a diferencia de
      # campo_descriptivo/1 (heurística automática, sigue siendo el
      # fallback si nadie configuró nada acá).
      campos_elegidos = campo_fk.schema_context_properties["campos_relacion"] || []

      %{
        catalogo: dep_nombre,
        etiqueta: dep_header.schema_context_label,
        total: CatalogoGenerico.contar(dep_mod, scope, filtro),
        filas: CatalogoGenerico.listar(dep_mod, scope, filtro, limit: 8),
        campo_descriptivo: campo_descriptivo(dep_nombre),
        columnas: columnas_tabla_relacion(dep_nombre, campos_elegidos)
      }
    end
  end

  # Campo que mejor describe una fila de `catalogo` para mostrarla en la
  # tabla de "Relaciones" (antes se mostraba solo el id crudo, ej. "#2",
  # sin ninguna pista de a qué producto correspondía). Heurística simple,
  # sin convención nueva que declarar catálogo por catálogo: el primer
  # campo VISIBLE de tipo texto, en el mismo orden ya configurado en el
  # Constructor — se calcula una sola vez por catálogo dependiente (no por
  # fila). Sin ningún campo texto visible, no hay nada mejor que mostrar
  # que el id (fallback en etiqueta_fila/2).
  defp campo_descriptivo(catalogo) do
    catalogo
    |> MetaSchemaContext.listar_detalles()
    |> Enum.filter(fn d -> d.schema_context_properties["visible"] and d.schema_context_properties["tipo"] == "string" end)
    |> Enum.sort_by(&get_in(&1.schema_context_properties, ["orden"]))
    |> case do
      [] -> nil
      [primero | _] -> String.to_existing_atom(primero.schema_context_field)
    end
  end

  defp etiqueta_fila(_fila, nil), do: nil
  defp etiqueta_fila(fila, campo) do
    case Map.get(fila, campo) do
      valor when valor not in [nil, ""] -> valor
      _ -> nil
    end
  end

  # "Campos a mostrar" del panel del Constructor (nodo "tabla") — mismo
  # orden en que se tildaron (no el orden del catálogo), así quien arma la
  # plantilla controla qué se ve primero.
  defp columnas_tabla_relacion(_catalogo, []), do: []

  defp columnas_tabla_relacion(catalogo, campos_elegidos) do
    detalles = MetaSchemaContext.listar_detalles(catalogo)

    Enum.map(campos_elegidos, fn campo ->
      etiqueta =
        case Enum.find(detalles, &(&1.schema_context_field == campo)) do
          nil -> campo
          d -> d.schema_context_properties["etiqueta"]
        end

      %{campo: String.to_existing_atom(campo), etiqueta: etiqueta}
    end)
  end

  # No existía ninguna consulta de "eventos de este registro" — se agrega
  # acá, de solo lectura, sin tocar cómo `MetaStateEngine` los escribe.
  #
  # Dos fuentes distintas, normalizadas a un mapa común (:origen, :inserted_at,
  # ...) para poder mezclarlas y ordenarlas juntas por fecha:
  # - TransicionEvento: transiciones del ENCABEZADO (alta/guardar/baja/...).
  # - meta_schema_auditoria (roadmap #6): altas/ediciones de los RENGLONES —
  #   crear_muchos/3 y dar_de_alta/5 nunca corren una transición propia por
  #   renglón (R3, los renglones no tienen autómata propio), así que agregar
  #   un renglón nuevo sin tocar ningún campo del encabezado no generaba
  #   ningún TransicionEvento — el Historial se veía vacío aunque sí había
  #   pasado algo. No se suma la auditoría del catálogo del ENCABEZADO acá
  #   (bc == tabla) a propósito: esa ya la cubre TransicionEvento cuando el
  #   catálogo adoptó el motor, sumar las dos duplicaría cada edición.
  defp cargar_historial(header_id, registro_id, catalogos_detalle, detalle_renglones) do
    eventos =
      from(e in TransicionEvento,
        where: e.meta_schema_header_id == ^header_id and e.registro_id == ^registro_id
      )
      |> Repo.all()

    usuarios_por_id = usuarios_por_id(Enum.map(eventos, & &1.usuario_id))

    transiciones =
      Enum.map(eventos, fn e ->
        %{
          origen: :transicion,
          inserted_at: e.inserted_at,
          accion: e.accion,
          estado_origen_id: e.estado_origen_id,
          estado_destino_id: e.estado_destino_id,
          # "usuario_id"/"empresa_id" viajan mezclados en el mismo mapa que
          # los campos REALES del formulario (ver Permissions.contexto_confiable/1
          # + evento_changeset/5 en MetaStateEngine, que los mergea antes de
          # persistir) — sin este Map.drop, "Modificó: ..." los listaba como
          # si fueran campos de negocio tocados por el usuario.
          contexto: Map.drop(e.contexto || %{}, ["usuario_id", "empresa_id"]),
          usuario: Map.get(usuarios_por_id, e.usuario_id)
        }
      end)

    auditorias =
      Enum.flat_map(catalogos_detalle, fn %{nombre: nombre, etiqueta: etiqueta} ->
        filas = Map.get(detalle_renglones, nombre, [])
        renglon_id_por_id = Map.new(filas, &{&1.id, &1.renglon_id})

        filas
        |> Enum.map(& &1.id)
        |> auditoria_de_renglones(nombre)
        |> Enum.map(fn a ->
          %{
            origen: :auditoria,
            inserted_at: a.inserted_at,
            accion: a.operacion,
            usuario: a.usuario_email,
            catalogo_etiqueta: etiqueta,
            renglon_id: Map.get(renglon_id_por_id, a.entidad_id)
          }
        end)
      end)

    (transiciones ++ auditorias) |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  defp auditoria_de_renglones([], _catalogo), do: []

  defp auditoria_de_renglones(ids, catalogo) do
    from(a in MetadataApp.MetaSchema.Auditoria, where: a.bc == ^catalogo and a.entidad_id in ^ids)
    |> Repo.all()
  end

  # Nombre legible (alias, o el usuario de antes de la @ del email —
  # Usuario.nombre_mostrar/1) para cada usuario_id de TransicionEvento —
  # a diferencia de meta_schema_auditoria (que ya guarda usuario_email en
  # texto plano), TransicionEvento solo persiste el id, así que hace
  # falta este lookup. Un solo Repo.all para TODO el historial (no uno
  # por fila) — usuario_id puede ser nil (contexto sin sesión resuelta,
  # ej. un seed/import), se descarta antes de la query en vez de fallar.
  defp usuarios_por_id([]), do: %{}

  defp usuarios_por_id(ids) do
    case Enum.reject(ids, &is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        from(u in MetadataApp.Autenticacion.Usuario, where: u.id in ^ids)
        |> Repo.all()
        |> Map.new(&{&1.id, MetadataApp.Autenticacion.Usuario.nombre_mostrar(&1)})
    end
  end

  # Mismos desenlaces que ya traduce CatalogoLive.formatear_error_transicion/1
  # para el modal de renglones — acá cubre además la ejecución de
  # transiciones de estado desde la Ficha 360°.
  defp formatear_error(:conflicto_concurrencia),
    do: "El estado del registro cambió mientras tenías la ficha abierta — actualízala e intentá de nuevo."

  defp formatear_error({:transicion_invalida, _}),
    do: "Esa transición ya no está disponible desde el estado actual — actualizá la ficha."

  defp formatear_error({:precondiciones, fallas}),
    do: Enum.map_join(fallas, " | ", & &1.mensaje)

  defp formatear_error(%Ecto.Changeset{} = changeset), do: MetadataApp.MetaErrores.resumen(changeset)
  defp formatear_error({:postcondicion_fallida, _}), do: "Error interno, no se aplicó el cambio."

  # Jerarquía operativa activa (Fase 5, 2026-08-11) -- CatalogoGenerico
  # devuelve esto cuando el catálogo exige branch/sales_unit/inventory
  # location y el usuario no tiene ninguno activo elegido (ver
  # CatalogoGenerico.validar_campo_requerido_en_attrs/4). Mensaje
  # accionable: le dice exactamente qué hacer (ir a la banda de pie), no
  # solo que algo falló.
  defp formatear_error({:alcance_requerido, "branch_id"}),
    do: "No tienes una Sucursal activa — elegí una desde la banda de pie para poder crear este registro."

  defp formatear_error({:alcance_requerido, "sales_unit_id"}),
    do: "No tienes una Unidad de Venta activa — elegí una desde la banda de pie para poder crear este registro."

  defp formatear_error({:alcance_requerido, "inventory_id"}),
    do: "No tienes un Almacén activo — elegí uno desde la banda de pie para poder crear este registro."

  defp formatear_error(_otro), do: "No se pudo completar la operación."

  # El botón de guardar lleva la etiqueta real de la transición "guardar"
  # configurada para este catálogo (ej. "Guardar", "Actualizar marca" — lo
  # que sea que se haya puesto en BcMotorLive), no un texto fijo — si el
  # catálogo no adoptó el motor de estados no hay transición de la que
  # sacar nada, así que cae a un genérico razonable.
  defp etiqueta_guardar(nil), do: "Guardar cambios"
  defp etiqueta_guardar(%{etiqueta: etiqueta}) when etiqueta not in [nil, ""], do: String.capitalize(etiqueta)
  defp etiqueta_guardar(_transicion), do: "Guardar cambios"

  def render(%{encontrado?: false} = assigns) do
    ~H"""
    <div class="p-8">
      <h1 class="text-xl font-bold">Catálogo no encontrado</h1>
      <p class="text-gray-500 mt-2">No hay ningún catálogo registrado con este nombre.</p>
    </div>
    """
  end

  def render(assigns) do
    contexto_formula = contexto_actual(assigns[:current_scope])

    assigns =
      assigns
      |> assign(
        :renglones_nuevos_count,
        contar_cambios_detalle(assigns.detalle_renglones_nuevos, assigns.detalle_renglones_editados, assigns.detalle_renglones_eliminados)
      )
      # Map.get/2, no @registro.trn — FichaLive es genérico para CUALQUIER
      # catálogo, y el campo :trn solo existe en el struct compilado si el
      # header estaba schema_es_transaccional: true en el momento en que
      # se generó ese schema (ver CatalogoGenerador.opciones_trn_use/1).
      # Un acceso directo (.trn) rompería con KeyError si el header quedó
      # marcado transaccional pero el módulo todavía no se regeneró/
      # publicó con ese campo (hallazgo real 2026-08-04, pty_gasto_diario).
      |> assign(:trn_registro, Map.get(assigns.registro, :trn))
      |> assign(:contexto_formula, contexto_formula)
      |> assign(
        :valores_calculados,
        valores_con_calculados(assigns.columnas, assigns.registro, assigns.form_values, contexto_formula, assigns.plantilla)
      )

    ~H"""
    <div class="p-6 max-w-5xl">
      <div :if={@plantilla_preview_id} class="text-xs rounded-lg px-3 py-2 mb-3 bg-purple-50 text-purple-700 flex items-center gap-2">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8Z" /><circle cx="12" cy="12" r="3" /></svg>
        <span>
          Vista previa de la plantilla <b>{@plantilla && @plantilla.nombre}</b>
          <span :if={@plantilla}>({@plantilla.estado})</span> — puede no ser la que ven los demás usuarios.
        </span>
      </div>

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm px-4 py-2.5 mb-3">
        <div class="flex items-center justify-between gap-4 flex-wrap">
          <div>
            <div class="flex items-center flex-wrap gap-2">
              <h1 :if={@modo == :alta} class="text-base font-bold text-gray-900">Nuevo — {@header.schema_context_label}</h1>
              <h1 :if={@modo == :ver} class="text-base font-bold text-gray-900">{@header.schema_context_label} #{@registro.id}</h1>
              <div :if={@modo == :ver} class="flex items-center flex-wrap gap-2 text-xs text-gray-500">
                <span :if={@mostrar_estado?} class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full bg-purple-50 text-purple-700 font-semibold">
                  {Map.get(@estados_por_id, @registro.estado_id) || "—"}
                </span>
                <span>{@relaciones_total} relaciones</span>
                <span :if={@header.schema_es_transaccional and @trn_registro} class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-gray-100 text-gray-600 font-mono">
                  TRN: {@trn_registro}
                  <button type="button" id={"copiar-trn-#{@registro.id}"} phx-hook="CopiarTexto" data-texto={@trn_registro}
                    title="Copiar TRN — para compartir o buscar este registro después" class="pc-breadcrumb-copiar">
                    <svg class="pc-breadcrumb-copiar-icono-copiar" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                      <rect x="9" y="9" width="12" height="12" rx="2" />
                      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
                    </svg>
                    <svg class="pc-breadcrumb-copiar-icono-listo" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                      <polyline points="20 6 9 17 4 12" />
                    </svg>
                  </button>
                </span>
                <span :if={@header.schema_es_transaccional and !@trn_registro} class="text-gray-400 italic">
                  Sin TRN (registro anterior a activar TRN en este catálogo)
                </span>
              </div>
            </div>
          </div>

          <div class="flex items-center gap-2 flex-wrap">
            <button :for={accion <- @acciones_externas} type="button"
              phx-click="ejecutar_accion_externa" phx-value-accion_id={accion.id}
              disabled={!is_nil(@accion_externa_en_curso)}
              data-confirm={if accion.confirmar_antes, do: "¿Ejecutar \"#{accion.etiqueta || accion.nombre}\"? Esto llama a #{accion.credencial.sistema_externo || accion.credencial.nombre} y puede modificar datos ahí."}
              class={[
                "px-2.5 py-1 rounded-lg text-xs font-semibold transition-colors border border-purple-200 text-purple-700 hover:bg-purple-50",
                !is_nil(@accion_externa_en_curso) && "opacity-50 cursor-not-allowed"
              ]}>
              {if @accion_externa_en_curso == accion.id, do: "Ejecutando…", else: accion.etiqueta || accion.nombre}
            </button>

            <button :for={t <- @otras_transiciones} type="button"
              phx-click="ejecutar_transicion" phx-value-accion={t.accion} disabled={!t.disponible}
              title={if !t.disponible, do: Enum.map_join(t.razones, "; ", & &1.mensaje)}
              class={[
                "px-2.5 py-1 rounded-lg text-xs font-semibold transition-colors border",
                t.disponible && "border-gray-300 text-gray-700 hover:bg-gray-50",
                !t.disponible && "border-gray-200 text-gray-300 cursor-not-allowed"
              ]}>
              {t.etiqueta}
            </button>

            <button :if={@es_detalle?} type="button" disabled title="Los campos de un renglón de catálogo detalle se editan mediante una transición del maestro"
              class="px-2.5 py-1 rounded-lg text-xs font-semibold border border-gray-200 text-gray-300 cursor-not-allowed">
              Editar
            </button>

            <div :if={!@es_detalle? and (@campos_editables != [] or @catalogos_detalle != [])} class="flex items-center gap-2">
              <span :if={@modo == :ver and map_size(@form_values) + @renglones_nuevos_count > 0}
                class="text-xs text-purple-700 font-semibold whitespace-nowrap">
                {map_size(@form_values) + @renglones_nuevos_count} cambio{if map_size(@form_values) + @renglones_nuevos_count == 1, do: "", else: "s"} sin guardar
              </span>
              <.link :if={@modo == :alta} navigate={@header.schema_context_nav}
                class="px-2.5 py-1 rounded-lg border border-gray-300 text-gray-700 text-xs font-semibold hover:bg-gray-50">
                Cancelar
              </.link>
              <button :if={@modo == :ver} type="button" phx-click="cancelar_edicion" disabled={map_size(@form_values) == 0}
                class="px-2.5 py-1 rounded-lg border border-gray-300 text-gray-700 text-xs font-semibold hover:bg-gray-50 disabled:opacity-40 disabled:cursor-not-allowed">
                Cancelar
              </button>
              <button type="button" phx-click="guardar"
                disabled={@modo == :ver and map_size(@form_values) == 0 and @renglones_nuevos_count == 0}
                class="px-2.5 py-1 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700 disabled:bg-gray-200 disabled:text-gray-400 disabled:cursor-not-allowed">
                {etiqueta_guardar(@transicion_edicion)}
              </button>
            </div>
          </div>
        </div>

        <div :if={@error_guardado} class="mt-2 bg-red-50 text-red-700 text-xs rounded-lg px-3 py-2 flex items-center justify-between gap-3">
          <span>{@error_guardado}</span>
          <button type="button" phx-click="actualizar_ficha" class="font-semibold whitespace-nowrap hover:underline">
            Actualizar ficha
          </button>
        </div>
      </div>

      <.modal_resultado_accion_externa :if={@resultado_accion_externa} resultado={@resultado_accion_externa} />

      <div class="flex gap-5 border-b border-gray-200 mb-4 text-sm">
        <button type="button" phx-click="cambiar_tab" phx-value-tab="datos"
          class={["pb-2 -mb-px font-semibold", @tab == "datos" && "text-purple-700 border-b-2 border-purple-600", @tab != "datos" && "text-gray-400"]}>
          Datos
        </button>
        <button :if={@catalogos_detalle != []} type="button" phx-click="cambiar_tab" phx-value-tab="detalle"
          class={["pb-2 -mb-px font-semibold", @tab == "detalle" && "text-purple-700 border-b-2 border-purple-600", @tab != "detalle" && "text-gray-400"]}>
          Detalle{if @renglones_nuevos_count > 0, do: " (#{@renglones_nuevos_count})"}
        </button>
        <button :if={@modo == :ver} type="button" phx-click="cambiar_tab" phx-value-tab="relaciones"
          class={["pb-2 -mb-px font-semibold", @tab == "relaciones" && "text-purple-700 border-b-2 border-purple-600", @tab != "relaciones" && "text-gray-400"]}>
          Relaciones ({@relaciones_total})
        </button>
        <button :if={@modo == :ver} type="button" phx-click="cambiar_tab" phx-value-tab="historial"
          class={["pb-2 -mb-px font-semibold", @tab == "historial" && "text-purple-700 border-b-2 border-purple-600", @tab != "historial" && "text-gray-400"]}>
          Historial
        </button>
      </div>

      <.tab_datos :if={@tab == "datos"} columnas={@columnas} registro={@registro} campos_editables={@campos_editables}
        plantilla={@plantilla} relaciones={@relaciones} estados_por_id={@estados_por_id} otras_transiciones={@otras_transiciones}
        edicion={%{valores: @form_values, errores: @errores_campos, contexto: @contexto_formula, calculados: @valores_calculados}} />
      <.tab_relaciones :if={@tab == "relaciones"} relaciones={@relaciones} />
      <.tab_historial :if={@tab == "historial"} historial={@historial} estados_por_id={@estados_por_id} />
      <.tab_detalle :if={@tab == "detalle"} modo={@modo} catalogos_detalle={@catalogos_detalle} detalle_renglones={@detalle_renglones}
        otras_transiciones={@otras_transiciones} detalle_form_error={@detalle_form_error} estados_por_id={@estados_por_id}
        detalle_seleccion={@detalle_seleccion} detalle_campos_editables={@detalle_campos_editables} />
    </div>
    """
  end

  # Respuesta CRUDA de la API externa (Fase 6, "Integraciones") — a
  # propósito sin interpretar/traducir el body: quien pone el botón (el
  # constructor del catálogo, vía AccionesExternasLive) es responsable de
  # que la URL/método tengan sentido; este modal solo demuestra que el
  # viaje de ida y vuelta ocurrió, para debug o confirmación visual.
  attr :resultado, :map, required: true

  defp modal_resultado_accion_externa(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/30 flex items-center justify-center z-50" phx-click="cerrar_resultado_accion_externa">
      <div class="bg-white rounded-2xl shadow-xl max-w-lg w-full mx-4 p-4" onclick="event.stopPropagation()">
        <div class="flex items-center justify-between mb-2">
          <h3 class="text-sm font-bold text-gray-900 flex items-center gap-2">
            <span class={["w-2 h-2 rounded-full", @resultado.ok? && "bg-green-500", !@resultado.ok? && "bg-red-500"]}></span>
            {@resultado.nombre || "Acción externa"}
          </h3>
          <button type="button" phx-click="cerrar_resultado_accion_externa" class="text-gray-400 hover:text-gray-600 text-lg leading-none">&times;</button>
        </div>

        <p :if={@resultado.status} class="text-xs text-gray-500 mb-2">HTTP {@resultado.status}</p>
        <p :if={@resultado.error} class="text-xs text-red-600 mb-2">{@resultado.error}</p>

        <pre :if={@resultado.body} class="bg-gray-50 border border-gray-200 rounded-lg p-2 text-[11px] font-mono overflow-auto max-h-64 whitespace-pre-wrap">{formatear_body_accion_externa(@resultado.body)}</pre>

        <div class="flex justify-end mt-3">
          <button type="button" phx-click="cerrar_resultado_accion_externa"
            class="px-3 py-1.5 rounded-lg bg-gray-100 text-gray-700 text-xs font-semibold hover:bg-gray-200">
            Cerrar
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp formatear_body_accion_externa(body) when is_map(body) or is_list(body), do: Jason.encode!(body, pretty: true)
  defp formatear_body_accion_externa(body), do: to_string(body)

  attr :columnas, :list, required: true
  attr :registro, :map, required: true
  attr :campos_editables, :list, required: true
  attr :plantilla, :any, default: nil
  attr :relaciones, :list, default: []
  attr :estados_por_id, :map, default: %{}
  attr :edicion, :map, required: true
  attr :otras_transiciones, :list, default: []

  # Sin plantilla publicada (el 100% de los catálogos hasta que alguien use
  # el Constructor): la lista plana de siempre, sin cambios. Con plantilla,
  # se recorre @plantilla.definicion — cada nodo "campo"/"tabla" reusa
  # exactamente campo_row/1 y tabla_relacion/1, así que el resultado nunca
  # se desincroniza de las reglas reales de campos_editables/relaciones.
  #
  # Edición en el lugar (no modal, sin toggle): un único <form> envuelve
  # todo el tab — cada campo editable ya es el input real (campo_input/1)
  # directo, siempre, sin un paso previo de "Editar". El botón de guardar
  # vive en el header (fuera de este form en el DOM) y lo dispara igual vía
  # form="form-ficha-datos".
  defp tab_datos(%{plantilla: nil} = assigns) do
    ~H"""
    <form id="form-ficha-datos" phx-change="validar" phx-submit="guardar">
      <div :if={map_size(@edicion.errores) > 0} class="bg-red-50 text-red-700 text-xs rounded-lg px-3 py-2 mb-3">
        No se pudo guardar: revisá los campos marcados en rojo.
      </div>
      <div class="bg-white border border-gray-200 rounded-xl overflow-hidden">
        <.campo_row :for={col <- @columnas} col={col} registro={@registro} campos_editables={@campos_editables} edicion={@edicion} />
        <p :if={@columnas == []} class="px-4 py-8 text-center text-gray-400 text-sm">Este catálogo no tiene campos visibles.</p>
      </div>
    </form>
    """
  end

  # La raíz de la plantilla ES un grid desde el arranque (ver moduledoc
  # "Grid 2D" de MetaPlantillas — ya no hay un "modo árbol" aparte en el
  # Constructor) — mismo render que cualquier otro tipos_grid_host/0
  # (Sección/Panel/Grid legado), solo que acá la raíz no tiene un "nodo"
  # propio con "id" (siempre existió como el mapa `definicion` pelado), así
  # que arma hijos_grid/estilo_grid_hijos directo sobre `@plantilla.definicion`
  # en vez de despachar por `nodo_plantilla_render/1`.
  defp tab_datos(assigns) do
    assigns =
      assigns
      |> assign(:estilo_grid, estilo_grid_hijos(assigns.plantilla.definicion))
      |> assign(:hijos, hijos_grid(assigns.plantilla.definicion))

    ~H"""
    <form id="form-ficha-datos" phx-change="validar" phx-submit="guardar" class="space-y-4">
      <div :if={map_size(@edicion.errores) > 0} class="bg-red-50 text-red-700 text-xs rounded-lg px-3 py-2">
        No se pudo guardar: revisá los campos marcados en rojo.
      </div>
      <div class="pc-grid-dinamica" style={@estilo_grid}>
        <.celda_grid :for={hijo <- @hijos} hijo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables}
          relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} otras_transiciones={@otras_transiciones} />
      </div>
      <p :if={@hijos == []} class="px-4 py-8 text-center text-gray-400 text-sm bg-white border border-gray-200 rounded-xl">
        La plantilla publicada todavía no tiene componentes.
      </p>
    </form>
    """
  end

  attr :nodo, :map, required: true
  attr :columnas, :list, required: true
  attr :registro, :map, required: true
  attr :campos_editables, :list, required: true
  attr :relaciones, :list, required: true
  attr :estados_por_id, :map, required: true
  attr :edicion, :map, required: true
  attr :otras_transiciones, :list, default: []

  # Envoltorio de condición: TODO nodo (cualquier tipo) puede tener
  # propiedades["condicion"] — %{"campo","operador","valor"} armado desde el
  # Constructor (panel_condicion/1 en PlantillaConstructorLive). Si no se
  # cumple, ni se intenta despachar por tipo — nodo_plantilla_render/1 (el
  # dispatch real por "tipo") ni se llama, así que agregar una condición
  # nunca necesita tocar cada cláusula por tipo por separado.
  defp nodo_plantilla(assigns) do
    ~H"""
    <.nodo_plantilla_render :if={condicion_cumplida?(@nodo, @registro, @estados_por_id)}
      nodo={@nodo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables}
      relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} otras_transiciones={@otras_transiciones} />
    """
  end

  attr :nodo, :map, required: true
  attr :columnas, :list, required: true
  attr :registro, :map, required: true
  attr :campos_editables, :list, required: true
  attr :relaciones, :list, required: true
  attr :estados_por_id, :map, required: true
  attr :edicion, :map, required: true
  attr :otras_transiciones, :list, default: []

  # "visible: false" oculta la sección entera (y lo que tenga adentro) en la
  # Ficha 360° — la propiedad la pone/quita quien diseña la plantilla desde
  # el Constructor, acá solo se respeta. Distinto de "condicion" (dinámica,
  # evaluada contra el registro): esto es un apagador fijo, manual.
  defp nodo_plantilla_render(%{nodo: %{"tipo" => "seccion", "propiedades" => %{"visible" => false}}} = assigns), do: ~H""

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "seccion", "propiedades" => %{"colapsable" => true}}} = assigns) do
    assigns =
      assigns
      |> assign(:padding, padding_seccion(assigns.nodo))
      |> assign(:estilo_grid, estilo_grid_hijos(assigns.nodo))
      |> assign(:hijos, hijos_grid(assigns.nodo))

    ~H"""
    <details class="bg-white border border-gray-200 rounded-xl overflow-hidden" open>
      <summary class={["cursor-pointer bg-gray-50 border-b border-gray-100 list-none", @padding]} style="list-style: none">
        <span class="font-bold text-gray-700 text-sm">
          <span :if={@nodo["propiedades"]["icono"] not in [nil, ""]}>{@nodo["propiedades"]["icono"]} </span>{@nodo["propiedades"]["titulo"]}
        </span>
        <div :if={@nodo["propiedades"]["descripcion"] not in [nil, ""]} class="text-xs text-gray-400 mt-0.5 font-normal">{@nodo["propiedades"]["descripcion"]}</div>
      </summary>
      <div class="pc-grid-dinamica p-3" style={@estilo_grid}>
        <.celda_grid :for={hijo <- @hijos} hijo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables}
          relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} otras_transiciones={@otras_transiciones} />
      </div>
    </details>
    """
  end

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "seccion"}} = assigns) do
    assigns =
      assigns
      |> assign(:padding, padding_seccion(assigns.nodo))
      |> assign(:estilo_grid, estilo_grid_hijos(assigns.nodo))
      |> assign(:hijos, hijos_grid(assigns.nodo))

    ~H"""
    <div class="bg-white border border-gray-200 rounded-xl overflow-hidden">
      <div class={["border-b border-gray-100 bg-gray-50", @padding]}>
        <div class="font-bold text-gray-700 text-sm">
          <span :if={@nodo["propiedades"]["icono"] not in [nil, ""]}>{@nodo["propiedades"]["icono"]} </span>{@nodo["propiedades"]["titulo"]}
        </div>
        <div :if={@nodo["propiedades"]["descripcion"] not in [nil, ""]} class="text-xs text-gray-400 mt-0.5">{@nodo["propiedades"]["descripcion"]}</div>
      </div>
      <div class="pc-grid-dinamica p-3" style={@estilo_grid}>
        <.celda_grid :for={hijo <- @hijos} hijo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables}
          relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} otras_transiciones={@otras_transiciones} />
      </div>
    </div>
    """
  end

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "fila"}} = assigns) do
    n = max(length(assigns.nodo["hijos"]), 1)
    assigns = assign(assigns, :estilo_grid, "--pc-fila-cols: #{n}")

    ~H"""
    <!-- Filas armadas a mano en el Constructor (plantilla_constructor_live)
         pueden tener cualquier cantidad de columnas — en vez de forzar ese
         mismo número de columnas fijas en un celular (ver .pc-fila-dinamica
         en app.css, que las colapsa a 1 columna bajo 640px), quedaría
         cada campo apretadísimo e ilegible. -->
    <div class="pc-fila-dinamica" style={@estilo_grid}>
      <.nodo_plantilla :for={hijo <- @nodo["hijos"]} nodo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables} relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} otras_transiciones={@otras_transiciones} />
    </div>
    """
  end

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "columna"}} = assigns) do
    ~H"""
    <div class="flex flex-col gap-3">
      <.nodo_plantilla :for={hijo <- @nodo["hijos"]} nodo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables} relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} otras_transiciones={@otras_transiciones} />
    </div>
    """
  end

  # Contenedor visual simple, sin encabezado — a diferencia de "seccion" no
  # tiene título/descripción, solo agrupa visualmente con borde + espaciado.
  defp nodo_plantilla_render(%{nodo: %{"tipo" => "panel"}} = assigns) do
    assigns =
      assigns
      |> assign(:padding, padding_seccion(assigns.nodo))
      |> assign(:estilo_grid, estilo_grid_hijos(assigns.nodo))
      |> assign(:hijos, hijos_grid(assigns.nodo))

    ~H"""
    <div class={["bg-white border border-gray-200 rounded-xl", @padding]}>
      <div class="pc-grid-dinamica" style={@estilo_grid}>
        <.celda_grid :for={hijo <- @hijos} hijo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables}
          relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} otras_transiciones={@otras_transiciones} />
      </div>
    </div>
    """
  end

  # Reusa <.tabs_motor> (core_components.ex) — el mismo componente de tabs
  # cliente-side (Phoenix.LiveView.JS, sin ida y vuelta al servidor) que ya
  # usa BcMotorLive para Configuración/Reglas/Diagrama/Contrato. El id de
  # cada pestaña es el id real del nodo "pestana" — único de por sí, no hace
  # falta inventar una clave aparte.
  defp nodo_plantilla_render(%{nodo: %{"tipo" => "pestanas"}} = assigns) do
    tabs_id = "pest-" <> assigns.nodo["id"]
    tabs = Enum.map(assigns.nodo["hijos"], &%{key: &1["id"], label: &1["propiedades"]["titulo"] || "Pestaña"})
    assigns = assigns |> assign(:tabs_id, tabs_id) |> assign(:tabs, tabs)

    ~H"""
    <div class="bg-white border border-gray-200 rounded-xl p-4">
      <.tabs_motor id={@tabs_id} tabs={@tabs} />
      <div :for={{pestana, i} <- Enum.with_index(@nodo["hijos"])} id={"#{@tabs_id}-panel-#{pestana["id"]}"} class={i != 0 && "hidden"}>
        <div class="pc-grid-dinamica" style={estilo_grid_hijos(pestana)}>
          <.celda_grid :for={hijo <- hijos_grid(pestana)} hijo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables}
            relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} otras_transiciones={@otras_transiciones} />
        </div>
      </div>
    </div>
    """
  end

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "campo"}} = assigns) do
    col = Enum.find(assigns.columnas, &(&1.schema_context_field == assigns.nodo["propiedades"]["campo"]))
    assigns = assign(assigns, :col, col)

    ~H"""
    <.campo_row :if={@col} col={@col} registro={@registro} campos_editables={@campos_editables} edicion={@edicion} />
    """
  end

  # Nunca editable, nunca se guarda — se recalcula en cada render contra
  # los valores EFECTIVOS del registro (lo que ya está tipeado en el form
  # sin guardar todavía, si lo hay; si no, el valor persistido). Así el
  # resultado se actualiza solo mientras se edita, sin código nuevo: ya
  # viaja por el mismo phx-change="validar" que dispara cualquier otro
  # campo del formulario. `edicion.calculados` (armado UNA sola vez por
  # render/1, ver valores_con_calculados/5) ya trae mezclados los campos
  # reales/contexto CON el resultado de cualquier otro campo_calculado de
  # la misma plantilla — así una fórmula puede referenciar "{OtroCampo}"
  # por su etiqueta, sin que Formula.ex necesite saber que eso existe (para
  # el evaluador es un campo más del mapa, como cualquier {campo} real).
  defp nodo_plantilla_render(%{nodo: %{"tipo" => "campo_calculado"}} = assigns) do
    formula = assigns.nodo["propiedades"]["formula"] || ""
    resultado = formula |> Formula.evaluar(assigns.edicion.calculados) |> Formula.formatear(assigns.nodo["propiedades"])
    assigns = assign(assigns, :resultado, resultado)

    ~H"""
    <div class="flex items-center gap-3 px-4 py-2.5 bg-white border border-gray-200 rounded-xl text-sm">
      <span class="w-5 flex-shrink-0 text-gray-400" title="Campo calculado">
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M9 3H8a2 2 0 0 0-2 2v3a2 2 0 0 1-2 2 2 2 0 0 1 2 2v3a2 2 0 0 0 2 2h1" />
          <path d="M15 3h1a2 2 0 0 1 2 2v3a2 2 0 0 0 2 2 2 2 0 0 0-2 2v3a2 2 0 0 1-2 2h-1" />
          <line x1="9" y1="12" x2="15" y2="12" />
        </svg>
      </span>
      <span class="w-56 flex-shrink-0 text-gray-500">{@nodo["propiedades"]["etiqueta"]}</span>
      <span class="text-gray-900 font-semibold">{@resultado}</span>
    </div>
    """
  end

  # Mira el valor ACTUAL (con cambios sin guardar incluidos, vía
  # valores_efectivos/3 — mismo criterio que "campo_calculado") de
  # CUALQUIER campo de ESTE catálogo (no exige tipo "referencia"), y lo
  # usa como id dinámico para buscar un registro puntual en otro catálogo
  # — no hace falta que estén relacionados. Solo lectura, nunca escribe en
  # otros campos: se recalcula solo con el mismo phx-change="validar" de
  # siempre.
  defp nodo_plantilla_render(%{nodo: %{"tipo" => "autocompletar"}} = assigns) do
    props = assigns.nodo["propiedades"]
    valores = valores_efectivos(assigns.columnas, assigns.registro, assigns.edicion.valores, assigns.edicion.contexto)
    id_texto = Map.get(valores, props["campo_referencia"] || "")
    # El checklist del Constructor manda "campos_destino[]" con un sentinel
    # vacío adelante (así un "ningún campo tildado" también llega como
    # lista, no como key ausente — mismo truco que ya usa el checkbox de
    # campo_input_components.ex) — se descarta acá, el único lugar donde
    # esta lista se lee de verdad.
    campos_destino = props["campos_destino"] |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))
    resultado = buscar_relacionado(props["catalogo_destino"], id_texto, campos_destino)
    assigns = assigns |> assign(:resultado, resultado) |> assign(:titulo, props["titulo"])

    ~H"""
    <div class="bg-white border border-gray-200 rounded-xl overflow-hidden">
      <div :if={@titulo not in [nil, ""]} class="px-4 py-2 border-b border-gray-100 bg-gray-50 font-bold text-gray-700 text-sm">
        {@titulo}
      </div>
      <div :if={match?({:ok, _}, @resultado)}>
        <div :for={{etiqueta, valor} <- elem(@resultado, 1)} class="flex items-center gap-3 px-4 py-2 border-b border-gray-100 last:border-b-0 text-sm">
          <span class="w-40 flex-shrink-0 text-gray-500">{etiqueta}</span>
          <span class="text-gray-900 font-medium">{valor}</span>
        </div>
      </div>
      <p :if={match?({:error, _}, @resultado)} class="px-4 py-3 text-center text-gray-400 text-xs">
        Elegí un valor en el campo de referencia para autocompletar.
      </p>
    </div>
    """
  end

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "divisor"}} = assigns) do
    ~H"""
    <hr class="border-gray-200" />
    """
  end

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "tabla"}} = assigns) do
    r = Enum.find(assigns.relaciones, &(&1.catalogo == assigns.nodo["propiedades"]["catalogo"]))

    campos_elegidos =
      assigns.nodo["propiedades"]["campos"] |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))

    columnas = if r, do: columnas_tabla_relacion(r.catalogo, campos_elegidos), else: []
    assigns = assigns |> assign(:r, r) |> assign(:columnas, columnas)

    ~H"""
    <.tabla_relacion :if={@r} r={@r} titulo={@nodo["propiedades"]["titulo"]} columnas={@columnas} />
    """
  end

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "etiqueta"}} = assigns) do
    ~H"""
    <div :if={@nodo["propiedades"]["estilo"] == "titulo"} class="text-sm font-bold text-gray-800 px-1">{@nodo["propiedades"]["texto"]}</div>
    <div :if={@nodo["propiedades"]["estilo"] != "titulo"} class="text-xs text-gray-500 px-1">{@nodo["propiedades"]["texto"]}</div>
    """
  end

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "alerta"}} = assigns) do
    ~H"""
    <div class={[
      "text-xs rounded-lg px-3 py-2 border",
      @nodo["propiedades"]["nivel"] == "error" && "bg-red-50 text-red-700 border-red-100",
      @nodo["propiedades"]["nivel"] == "advertencia" && "bg-amber-50 text-amber-700 border-amber-100",
      (@nodo["propiedades"]["nivel"] not in ["error", "advertencia"]) && "bg-blue-50 text-blue-700 border-blue-100"
    ]}>
      {@nodo["propiedades"]["texto"]}
    </div>
    """
  end

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "tarjeta"}} = assigns) do
    ~H"""
    <div class="bg-white border border-gray-200 rounded-xl px-4 py-3 border-l-4 border-l-purple-400">
      <div class="font-bold text-gray-700 text-sm">
        <span :if={@nodo["propiedades"]["icono"] not in [nil, ""]}>{@nodo["propiedades"]["icono"]} </span>{@nodo["propiedades"]["titulo"]}
      </div>
      <div :if={@nodo["propiedades"]["texto"] not in [nil, ""]} class="text-xs text-gray-500 mt-1">{@nodo["propiedades"]["texto"]}</div>
    </div>
    """
  end

  # Bloque "grid" (Constructor visual tipo hoja de cálculo — ver moduledoc
  # "Grid 2D" de MetaPlantillas). A diferencia de "fila" (columnas iguales,
  # orden de lista = orden visual), acá cada hijo lleva su posición real en
  # propiedades["celda"] — celda_grid/1 hace de puente entre esa metadata y
  # el <div> real posicionado con CSS Grid explícito (grid-column/grid-row),
  # SIN ningún borde de grilla (eso es solo del Constructor, ver .gc-editor
  # en app.css) — .pc-grid-dinamica colapsa a 1 columna bajo 640px salvo que
  # el nodo pida un override puntual (responsive.colspan_movil/orden_movil).
  defp nodo_plantilla_render(%{nodo: %{"tipo" => "grid"}} = assigns) do
    assigns = assigns |> assign(:estilo_grid, estilo_grid_hijos(assigns.nodo)) |> assign(:hijos, hijos_grid(assigns.nodo))

    ~H"""
    <div class="pc-grid-dinamica" style={@estilo_grid}>
      <.celda_grid :for={hijo <- @hijos} hijo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables}
        relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} otras_transiciones={@otras_transiciones} />
    </div>
    """
  end

  # Dispara una transición YA CONFIGURADA del catálogo (mismo mecanismo que
  # los botones de transición del encabezado, ver phx-click="ejecutar_transicion"
  # más arriba) — nunca código arbitrario. Si "accion" no está entre
  # @otras_transiciones (no aplica al estado actual, o typo al configurar la
  # plantilla) el botón queda deshabilitado solo, con el mismo motivo que ya
  # explica por qué una transición no está disponible.
  defp nodo_plantilla_render(%{nodo: %{"tipo" => "boton"}} = assigns) do
    accion = assigns.nodo["propiedades"]["accion"]
    transicion = accion not in [nil, ""] && Enum.find(assigns.otras_transiciones, &(&1.accion == accion))
    disponible? = match?(%{disponible: true}, transicion)

    titulo =
      case transicion do
        %{disponible: false, razones: razones} -> Enum.map_join(razones, "; ", & &1.mensaje)
        false -> "Esta acción no está disponible en el estado actual."
        _ -> nil
      end

    assigns = assigns |> assign(:disponible?, disponible?) |> assign(:titulo, titulo) |> assign(:accion, accion)

    ~H"""
    <button type="button" phx-click="ejecutar_transicion" phx-value-accion={@accion} disabled={!@disponible?} title={@titulo}
      class={[
        "px-4 py-2 rounded-lg text-sm font-semibold",
        @nodo["propiedades"]["estilo"] != "secundario" && @disponible? && "bg-purple-600 text-white hover:bg-purple-700",
        @nodo["propiedades"]["estilo"] == "secundario" && @disponible? && "border border-purple-300 text-purple-700 hover:bg-purple-50",
        !@disponible? && "border border-gray-200 text-gray-300 cursor-not-allowed"
      ]}>
      {@nodo["propiedades"]["etiqueta"]}
    </button>
    """
  end

  defp nodo_plantilla_render(assigns), do: ~H""

  # Hijos de CUALQUIER contenedor-grid (raíz/seccion/panel/pestana/grid, ver
  # MetaPlantillas.tipos_grid_host/0) con la celda YA resuelta en grupo —
  # nunca celda_de/1 nodo por nodo (eso apilaría en la misma celda a
  # cualquier plantilla vieja de un catálogo que todavía no pasó por acá,
  # ver MetaPlantillas.celdas_resueltas/1 para el detalle de la migración
  # en memoria).
  defp hijos_grid(nodo), do: MetaPlantillas.celdas_resueltas(nodo["hijos"] || [])

  defp estilo_grid_hijos(nodo) do
    n = nodo["propiedades"]["columnas"] || 1
    gap = %{"compacto" => "8px", "amplio" => "20px"}[nodo["propiedades"]["gap"]] || "12px"
    "--pc-grid-cols: #{n}; --pc-grid-gap: #{gap}"
  end

  attr :hijo, :map, required: true
  attr :columnas, :list, required: true
  attr :registro, :map, required: true
  attr :campos_editables, :list, required: true
  attr :relaciones, :list, required: true
  attr :estados_por_id, :map, required: true
  attr :edicion, :map, required: true
  attr :otras_transiciones, :list, default: []

  defp celda_grid(assigns) do
    celda = Map.merge(MetaPlantillas.celda_default(), assigns.hijo["propiedades"]["celda"] || %{})
    responsive = celda["responsive"] || %{}

    # Un "campo" adentro de una celda usa campo_row/1 en modo "compacto"
    # (etiqueta de ancho automático en vez del w-56 fijo que campo_row usa
    # para alinear una LISTA de renglones apilados, ver tab_datos sin
    # plantilla) — una celda angosta con esa etiqueta fija dejaba casi sin
    # lugar al input real (bug real, reportado: el campo se veía diminuto).
    # Cualquier otro tipo sigue el dispatch genérico de nodo_plantilla_render/1.
    campo_col =
      if assigns.hijo["tipo"] == "campo" do
        Enum.find(assigns.columnas, &(&1.schema_context_field == assigns.hijo["propiedades"]["campo"]))
      end

    assigns =
      assigns
      |> assign(:celda, celda)
      |> assign(:responsive, responsive)
      |> assign(:estilo_celda, estilo_celda(celda))
      |> assign(:clases_celda, celda_classes(celda))
      |> assign(:campo_col, campo_col)

    ~H"""
    <div :if={@celda["visible"] != false} style={@estilo_celda} class={@clases_celda}
      data-celda-colspan-movil={@responsive["colspan_movil"]} data-celda-orden-movil={@responsive["orden_movil"]}>
      <.campo_row :if={@campo_col} col={@campo_col} registro={@registro} campos_editables={@campos_editables} edicion={@edicion} compacto={true} />
      <.nodo_plantilla :if={is_nil(@campo_col)} nodo={@hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables}
        relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} otras_transiciones={@otras_transiciones} />
    </div>
    """
  end

  defp estilo_celda(celda) do
    base = "grid-column: #{celda["columna"] + 1} / span #{celda["colspan"]}; grid-row: #{celda["fila"] + 1} / span #{celda["rowspan"]};"
    ancho = if celda["ancho"] not in [nil, ""], do: "width: #{celda["ancho"]};", else: ""
    alto = if celda["alto"] not in [nil, ""], do: "height: #{celda["alto"]};", else: ""
    responsive = celda["responsive"] || %{}
    colspan_movil = if responsive["colspan_movil"], do: "--celda-colspan-movil: #{responsive["colspan_movil"]};", else: ""
    orden_movil = if responsive["orden_movil"], do: "--celda-orden-movil: #{responsive["orden_movil"]};", else: ""

    base <> ancho <> alto <> colspan_movil <> orden_movil
  end

  @doc false
  # Clases Tailwind de una celda de grid — alineación/padding/estilo curado
  # (misma paleta corta que ofrece panel_celda/1 en el Constructor, nunca
  # CSS libre). `false`/`nil` en la lista simplemente no imprimen nada
  # (Phoenix ya descarta esas entradas al armar el atributo `class`).
  defp celda_classes(celda) do
    estilo = celda["estilo"] || %{}

    [
      "min-w-0",
      alineacion_h_class(celda["alineacion_h"]),
      alineacion_v_class(celda["alineacion_v"]),
      padding_celda_class(celda["padding"]),
      estilo["fondo"] not in [nil, ""] && swatch_fondo(estilo["fondo"]),
      estilo["color_texto"] not in [nil, ""] && swatch_texto(estilo["color_texto"]),
      estilo["borde"] == true && "border border-gray-200",
      estilo["redondeado"] == true && "rounded-lg",
      estilo["sombra"] == true && "shadow-sm",
      get_in(celda, ["responsive", "ocultar_movil"]) == true && "pc-celda-ocultar-movil"
    ]
  end

  # SIEMPRE justify-self-stretch — "alineación horizontal" solo mueve el
  # TEXTO/contenido adentro de una celda que ya llena su ancho completo
  # (mismo criterio que "Ancho" para controlar tamaño real, si alguna vez
  # hace falta uno angosto). `justify-self-start/center/end` (achicar la
  # celda al tamaño de su contenido) fue el diseño original, pero volvía
  # "Izquierda" (que suena inocuo, y encima quedaba de default) en un
  # <input> encogido al ancho de lo que tenía tipeado — bug real,
  # reportado — en vez de llenar la celda como cualquier campo esperaría.
  defp alineacion_h_class("centro"), do: "justify-self-stretch text-center"
  defp alineacion_h_class("derecha"), do: "justify-self-stretch text-right"
  defp alineacion_h_class("justificado"), do: "justify-self-stretch text-justify"
  defp alineacion_h_class(_), do: "justify-self-stretch text-left"

  defp alineacion_v_class("centro"), do: "self-center"
  defp alineacion_v_class("abajo"), do: "self-end"
  defp alineacion_v_class("estirar"), do: "self-stretch"
  defp alineacion_v_class(_), do: "self-start"

  defp padding_celda_class("ninguno"), do: "p-0"
  defp padding_celda_class("compacto"), do: "p-1.5"
  defp padding_celda_class("amplio"), do: "p-5"
  defp padding_celda_class(_), do: "p-3"

  defp swatch_fondo(nombre) do
    Map.get(
      %{"gris" => "bg-gray-100", "purpura" => "bg-purple-100", "azul" => "bg-blue-100", "verde" => "bg-green-100", "amarillo" => "bg-amber-100", "rojo" => "bg-red-100"},
      nombre
    )
  end

  defp swatch_texto(nombre) do
    Map.get(
      %{"gris" => "text-gray-700", "purpura" => "text-purple-700", "azul" => "text-blue-700", "verde" => "text-green-700", "amarillo" => "text-amber-700", "rojo" => "text-red-700"},
      nombre
    )
  end

  # "condicion" (dinámica, ver panel_condicion en PlantillaConstructorLive):
  # %{"campo","operador","valor"} — "campo" puede ser un campo real del
  # catálogo o el pseudo-campo "__estado__" (nombre del estado actual, vía
  # estados_por_id). Fail-open a propósito: cualquier condición mal formada
  # o que referencie un campo que ya no existe no rompe la Ficha 360°, el
  # componente simplemente se muestra.
  defp condicion_cumplida?(nodo, registro, estados_por_id) do
    case nodo["propiedades"]["condicion"] do
      %{"campo" => campo} = condicion when campo not in [nil, ""] ->
        evaluar_condicion(condicion, registro, estados_por_id)

      _ ->
        true
    end
  rescue
    _ -> true
  end

  defp evaluar_condicion(%{"campo" => "__estado__", "operador" => operador} = condicion, registro, estados_por_id) do
    nombre_estado = Map.get(estados_por_id, registro.estado_id) || ""
    comparar_condicion(operador, nombre_estado, condicion["valor"])
  end

  defp evaluar_condicion(%{"campo" => campo, "operador" => operador} = condicion, registro, _estados_por_id) do
    valor_actual = Map.get(registro, String.to_existing_atom(campo))
    comparar_condicion(operador, valor_actual, condicion["valor"])
  end

  defp comparar_condicion("igual", actual, esperado), do: to_string(actual) == to_string(esperado || "")
  defp comparar_condicion("distinto", actual, esperado), do: to_string(actual) != to_string(esperado || "")
  defp comparar_condicion("vacio", actual, _esperado), do: actual in [nil, ""]
  defp comparar_condicion("no_vacio", actual, _esperado), do: actual not in [nil, ""]
  defp comparar_condicion(_otro, _actual, _esperado), do: true

  defp padding_seccion(%{"propiedades" => %{"espaciado" => "compacto"}}), do: "px-3 py-1.5"
  defp padding_seccion(%{"propiedades" => %{"espaciado" => "amplio"}}), do: "px-5 py-4"
  defp padding_seccion(_nodo), do: "px-4 py-2.5"

  # Los 3 pseudo-campos de "Contexto" — se usan igual que cualquier campo
  # real, con la misma sintaxis "{hoy}"/"{usuario_actual}"/"{empresa_activa}"
  # (ver Formula, que no sabe ni le importa de dónde salió cada valor del
  # mapa que recibe). Sin sesión resuelta (nadie logueado, o en medio de
  # elegir empresa) los dos últimos quedan vacíos en vez de romper nada.
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

  # Mapa campo => valor "de verdad" para un "campo_calculado": lo que el
  # usuario ya tipeó en el form (sin guardar todavía) tiene prioridad sobre
  # lo persistido — mismo criterio que ya usa campo_row/1 para precargar
  # cada input (valor_mostrado). Los pseudo-campos de Contexto (hoy,
  # usuario_actual, empresa_activa) se mezclan atrás — un campo real con
  # ese mismo nombre (rarísimo, pero por las dudas) siempre gana.
  defp valores_efectivos(columnas, registro, valores_form, contexto) do
    valores_reales =
      Enum.reduce(columnas, %{}, fn col, acc ->
        campo = col.schema_context_field
        valor = Map.get(valores_form, campo) || Map.get(registro, String.to_existing_atom(campo))
        Map.put(acc, campo, valor)
      end)

    Map.merge(contexto, valores_reales)
  end

  # valores_efectivos/4 + el resultado de CUALQUIER campo_calculado de la
  # plantilla, mezclado en el mismo mapa bajo su "etiqueta" — así una
  # fórmula puede escribir "{OtroCampo}" igual que escribiría "{campo_real}",
  # sin sintaxis especial (Formula.resolver_campo/2 ya hace un Map.get/2
  # plano, no le importa de dónde salió cada valor). Se resuelve UNA vez
  # por render (ver render/1), no una vez por nodo — evita recalcular la
  # misma dependencia N veces si varios campos_calculados la comparten.
  #
  # Sin plantilla (el caso común, ningún catálogo publicó una todavía):
  # ningún campo_calculado que buscar, se devuelve valores_efectivos/4 tal
  # cual, mismo costo que antes de que existiera esto.
  defp valores_con_calculados(_columnas, _registro, _valores_form, _contexto, nil), do: %{}

  defp valores_con_calculados(columnas, registro, valores_form, contexto, plantilla) do
    columnas
    |> valores_efectivos(registro, valores_form, contexto)
    |> then(&Formula.resolver_calculados(plantilla.definicion, &1))
  end

  # id dinámico (lo que el usuario tipeó en el campo referencia) en vez de
  # fijo — mismo espíritu que Formula's "{catalogo#id.campo}", pero acá
  # trae VARIOS campos de una y nunca ejecuta nada, solo un obtener! con
  # rescue. Fail-open: sin selección, catálogo/campo inexistente, o
  # registro borrado, siempre {:error, _} — nunca crashea la ficha.
  defp buscar_relacionado(catalogo, _id_texto, _campos_destino) when catalogo in [nil, ""], do: {:error, :sin_configurar}
  defp buscar_relacionado(_catalogo, _id_texto, []), do: {:error, :sin_configurar}

  defp buscar_relacionado(catalogo, id_texto, campos_destino) do
    with {id, ""} <- Integer.parse(to_string(id_texto || "")),
         modulo when not is_nil(modulo) <- MetaSchemaContext.modulo_por_nombre(catalogo) do
      try do
        # :sistema (Fase 4a) -- nodo de plantilla ("autocompletar"), es un
        # componente de función (nodo_plantilla_render/1) sin acceso directo
        # al Scope del socket; mismo criterio que Formula (helper de
        # preview/cálculo, no el listado principal de la ficha). Pendiente
        # marcado si en el futuro se justifica threadear el Scope por todo
        # el árbol de render de plantilla.
        registro = CatalogoGenerico.obtener!(modulo, :sistema, id)
        etiquetas = etiquetas_de_campos(catalogo, campos_destino)

        filas =
          Enum.map(campos_destino, fn campo ->
            etiqueta = Map.get(etiquetas, campo, campo)
            valor = Map.get(registro, String.to_existing_atom(campo))
            {etiqueta, (valor not in [nil, ""] && valor) || "—"}
          end)

        {:ok, filas}
      rescue
        Ecto.NoResultsError -> {:error, :no_encontrado}
        ArgumentError -> {:error, :campo_invalido}
      end
    else
      _ -> {:error, :sin_seleccion}
    end
  end

  defp etiquetas_de_campos(catalogo, campos_destino) do
    catalogo
    |> MetaSchemaContext.listar_detalles()
    |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
    |> Enum.filter(&(&1.schema_context_field in campos_destino))
    |> Map.new(&{&1.schema_context_field, &1.schema_context_properties["etiqueta"]})
  end

  attr :col, :map, required: true
  attr :registro, :map, required: true
  attr :campos_editables, :list, required: true
  attr :edicion, :map, required: true
  attr :compacto, :boolean, default: false

  # Edición en el lugar, siempre: si el campo es editable, la columna de
  # "valor" ya ES el input real (campo_input/1, el mismo que comparten
  # "+ Agregar renglón" y el Constructor), sin ningún paso previo de
  # "Editar" — el campo que no es editable simplemente sigue de solo
  # lectura al lado, nunca se deshabilita en masa nada.
  defp campo_row(assigns) do
    editable? = assigns.col.schema_context_field in assigns.campos_editables
    campo_atom = String.to_existing_atom(assigns.col.schema_context_field)
    props = assigns.col.schema_context_properties

    valor_actual = Map.get(assigns.registro, campo_atom)

    valor_mostrado =
      Map.get(assigns.edicion.valores, assigns.col.schema_context_field, to_string(valor_actual))

    errores_campo = Map.get(assigns.edicion.errores, campo_atom)

    # Referencia: mismo picker/etiqueta tanto editable como de solo lectura
    # (ya resuelve "campos de acompañamiento" configurados en BcMotorLive →
    # Relaciones) — antes acá se mostraba el id crudo (editable, una caja
    # de texto libre; solo lectura, el número pelado), sin ninguna pista de
    # a qué apunta. Precalculado en cargar_catalogos_detalle/1 (col.opciones)
    # — nunca se vuelve a consultar acá, esto corre en cada render.
    {opciones_referencia, deshabilitado_dependencia, mensaje_dependencia} =
      resolver_info_dependencia(props, Map.get(assigns.col, :opciones, []), fn campo ->
        Map.get(assigns.edicion.valores, campo) || valor_registro_seguro(assigns.registro, campo)
      end)

    valor_legible = if props["tipo"] == "referencia", do: etiqueta_opcion(opciones_referencia, valor_actual), else: valor_actual

    assigns =
      assigns
      |> assign(:editable?, editable?)
      |> assign(:valor_actual, valor_actual)
      |> assign(:valor_mostrado, valor_mostrado)
      |> assign(:errores_campo, errores_campo)
      |> assign(:opciones_referencia, opciones_referencia)
      |> assign(:deshabilitado_dependencia, deshabilitado_dependencia)
      |> assign(:mensaje_dependencia, mensaje_dependencia)
      |> assign(:valor_legible, valor_legible)

    ~H"""
    <div class={[
      "flex flex-col sm:flex-row sm:items-center text-sm",
      @compacto && "gap-2",
      !@compacto && "gap-1.5 sm:gap-3 px-4 py-2.5 border-b border-gray-100 last:border-b-0"
    ]}>
      <div class={["flex items-center gap-2 sm:contents", !@compacto && "gap-3"]}>
        <span class="w-5 flex-shrink-0 text-gray-400 self-start mt-0.5">
          <svg :if={@editable?} width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="text-purple-600">
            <path d="M12 20h9" /><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" />
          </svg>
          <svg :if={!@editable?} width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <rect x="4" y="10" width="16" height="11" rx="2" /><path d="M8 10V7a4 4 0 0 1 8 0v3" />
          </svg>
        </span>
        <span class={["flex-shrink-0 text-gray-500 self-start mt-0.5", @compacto && "whitespace-nowrap", !@compacto && "w-full sm:w-56"]}>
          {@col.schema_context_properties["etiqueta"]}
          <span :if={@editable? and @col.schema_context_properties["tipo"] != "boolean"} class="text-red-500">*</span>
        </span>
      </div>

      <div :if={@editable?} class="flex-1 min-w-0">
        <.campo_input columna={@col} valor={@valor_mostrado} mostrar_etiqueta={false} opciones={@opciones_referencia}
          disabled={@deshabilitado_dependencia} mensaje_dependencia={@mensaje_dependencia} />
        <p :if={@errores_campo} class="text-red-600 text-xs mt-1">{Enum.join(@errores_campo, "; ")}</p>
      </div>
      <span :if={!@editable?} class="text-gray-900 font-medium truncate">
        {(@valor_legible not in [nil, ""] && @valor_legible) || "—"}
      </span>
    </div>
    """
  end

  defp etiqueta_opcion(_opciones, nil), do: nil

  defp etiqueta_opcion(opciones, id) do
    case Enum.find(opciones, fn {oid, _etiqueta} -> oid == id end) do
      {_id, etiqueta} -> etiqueta
      nil -> "##{id}"
    end
  end

  attr :relaciones, :list, required: true

  defp tab_relaciones(assigns) do
    ~H"""
    <div class="space-y-4">
      <.tabla_relacion :for={r <- @relaciones} r={r} titulo={"#{r.etiqueta} (#{r.total})"} columnas={r.columnas} />
      <p :if={@relaciones == []} class="text-center text-gray-400 text-sm py-8">Ningún catálogo depende de este registro.</p>
    </div>
    """
  end

  attr :r, :map, required: true
  attr :titulo, :string, required: true
  attr :columnas, :list, default: []

  # Sin @columnas (el tab "Relaciones" genérico, siempre así — no hay
  # config por catálogo ahí): una sola columna con campo_descriptivo/2 +
  # id. Con @columnas (nodo "tabla" del Constructor, con "Campos a
  # mostrar" elegidos a mano): una columna real por campo elegido, en el
  # mismo orden en que se tildaron.
  defp tabla_relacion(assigns) do
    ~H"""
    <div class="bg-white border border-gray-200 rounded-xl overflow-hidden">
      <div class="flex items-center justify-between px-4 py-2.5 border-b border-gray-100 bg-gray-50">
        <span class="font-bold text-gray-700 text-sm">{@titulo}</span>
      </div>
      <div class="overflow-x-auto">
        <table class="min-w-full text-xs">
          <thead :if={@columnas != []} class="bg-gray-50">
            <tr>
              <th :for={col <- @columnas} class="px-4 py-2 text-left text-[10px] font-semibold text-gray-500 uppercase tracking-wide">{col.etiqueta}</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-50">
            <tr :for={fila <- @r.filas} class="hover:bg-purple-50/60">
              <%= if @columnas == [] do %>
                <td class="px-4 py-1.5 text-gray-700">
                  <%= if descripcion = etiqueta_fila(fila, @r.campo_descriptivo) do %>
                    {descripcion} <span class="text-gray-400">· #{fila.id}</span>
                  <% else %>
                    <span class="text-gray-500">#{fila.id}</span>
                  <% end %>
                </td>
              <% else %>
                <td :for={col <- @columnas} class="px-4 py-1.5 text-gray-700">
                  {(Map.get(fila, col.campo) not in [nil, ""] && Map.get(fila, col.campo)) || "—"}
                </td>
              <% end %>
              <td class="px-4 py-1.5 text-right">
                <.link navigate={"/registro/#{@r.catalogo}/#{fila.id}"} class="text-purple-700 font-semibold hover:underline">
                  Ver ficha
                </.link>
              </td>
            </tr>
            <tr :if={@r.filas == []}>
              <td class="px-4 py-4 text-center text-gray-400" colspan={max(length(@columnas), 1) + 1}>Sin registros todavía.</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :historial, :list, required: true
  attr :estados_por_id, :map, required: true

  # Dos tipos de fila mezcladas, ya ordenadas por fecha (ver
  # cargar_historial/4) — :transicion es lo de siempre (encabezado);
  # :auditoria son altas/ediciones de renglones, sin transición propia.
  defp tab_historial(assigns) do
    ~H"""
    <div class="bg-white border border-gray-200 rounded-xl overflow-hidden">
      <div :for={e <- @historial} class="px-4 py-2.5 border-b border-gray-100 last:border-b-0 text-sm">
        <div :if={e.origen == :transicion} class="flex items-center gap-2 flex-wrap">
          <span class="font-mono text-[11px] text-gray-400">{Calendar.strftime(e.inserted_at, "%d/%m/%Y %H:%M")}</span>
          <span class="px-2 py-0.5 rounded-full bg-gray-100 text-gray-600 text-[11px] font-semibold">{e.accion}</span>
          <span class="text-gray-400 text-[11px]">
            {Map.get(@estados_por_id, e.estado_origen_id) || "—"} → {Map.get(@estados_por_id, e.estado_destino_id) || "—"}
          </span>
          <span :if={e.usuario} class="text-gray-400 text-[11px]">· {e.usuario}</span>
        </div>
        <div :if={e.origen == :transicion and map_size(e.contexto) > 0} class="text-xs text-gray-500 mt-1">
          Modificó: {Enum.join(Map.keys(e.contexto), ", ")}
        </div>

        <div :if={e.origen == :auditoria} class="flex items-center gap-2 flex-wrap">
          <span class="font-mono text-[11px] text-gray-400">{Calendar.strftime(e.inserted_at, "%d/%m/%Y %H:%M")}</span>
          <span class="px-2 py-0.5 rounded-full bg-purple-50 text-purple-700 text-[11px] font-semibold">
            {e.catalogo_etiqueta}{if e.renglon_id, do: " #{e.renglon_id}"} · {e.accion}
          </span>
          <span :if={e.usuario} class="text-gray-400 text-[11px]">{e.usuario}</span>
        </div>
      </div>
      <p :if={@historial == []} class="px-4 py-8 text-center text-gray-400 text-sm">Sin eventos todavía.</p>
    </div>
    """
  end

  attr :modo, :atom, required: true
  attr :catalogos_detalle, :list, required: true
  attr :detalle_renglones, :map, required: true
  attr :otras_transiciones, :list, default: []
  attr :detalle_form_error, :string, default: nil
  attr :estados_por_id, :map, required: true
  attr :detalle_seleccion, :map, required: true
  attr :detalle_campos_editables, :list, default: []

  # Layout tipo IDE (editor fijo + área de trabajo amplia): un catálogo
  # detalle = un par formulario (1/3, izquierda) + tabla (2/3, derecha),
  # apilados verticalmente si hay más de un catálogo detalle. El
  # formulario nunca es un modal ni una fila expandida — siempre muestra
  # el renglón "seleccionado" en la tabla de al lado (ver
  # panel_detalle_catalogo/1).
  defp tab_detalle(assigns) do
    ~H"""
    <div class="space-y-4">
      <div :if={@detalle_form_error} class="bg-red-50 text-red-700 text-xs rounded-lg px-3 py-2">{@detalle_form_error}</div>

      <.panel_detalle_catalogo :for={cat <- @catalogos_detalle} cat={cat}
        filas={Map.get(@detalle_renglones, cat.nombre, [])} otras_transiciones={@otras_transiciones}
        estados_por_id={@estados_por_id} seleccion={Map.get(@detalle_seleccion, cat.nombre)}
        campos_editables={@detalle_campos_editables} />
    </div>
    """
  end

  attr :cat, :map, required: true
  attr :filas, :list, required: true
  attr :otras_transiciones, :list, required: true
  attr :estados_por_id, :map, required: true
  attr :seleccion, :map, default: nil
  attr :campos_editables, :list, default: []

  defp panel_detalle_catalogo(assigns) do
    ~H"""
    <div class="bg-white border border-gray-200 rounded-xl overflow-hidden">
      <div class="px-4 py-2.5 border-b border-gray-100 bg-gray-50">
        <span class="font-bold text-gray-700 text-sm">{@cat.etiqueta}</span>
      </div>

      <div class="border-b border-gray-100">
        <.formulario_renglon cat={@cat} seleccion={@seleccion} total={length(@filas)} campos_editables={@campos_editables} />
      </div>

      <div class="overflow-x-auto">
        <GridEditableComponents.grid id={"grid-#{@cat.nombre}"} catalogo={@cat.nombre} columnas={@cat.columnas_tabla}
          filas_existentes={@filas} transiciones_disponibles={@otras_transiciones} estados_por_id={@estados_por_id} />
      </div>
    </div>
    """
  end

  attr :cat, :map, required: true
  attr :seleccion, :map, default: nil
  attr :total, :integer, required: true
  attr :campos_editables, :list, default: []

  defp formulario_renglon(assigns) do
    # Un renglón YA PERSISTIDO solo se puede tocar si al menos uno de sus
    # campos está en la whitelist campos_editables de la transición
    # "guardar" resuelta (ver campo_detalle_editable?/3 más abajo, que
    # aplica el mismo criterio campo por campo) — una línea NUEVA siempre
    # es editable, esa restricción no le aplica (el alta no pasa por
    # ninguna transición, ver crear_renglones_nuevos/3).
    bloqueado? =
      assigns.seleccion && assigns.seleccion.renglon_id &&
        not Enum.any?(assigns.cat.columnas, &(&1.schema_context_field in assigns.campos_editables))

    assigns = assign(assigns, :bloqueado?, bloqueado?)

    ~H"""
    <div class="flex flex-col">
      <div class="px-4 py-2 border-b border-gray-100 bg-gray-50 flex items-center justify-between gap-2">
        <div class="text-[11px] font-semibold text-gray-500 uppercase tracking-wide flex items-center gap-1.5">
          <%= cond do %>
            <% is_nil(@seleccion) -> %>
              <span class="text-gray-300">–</span> Preparando línea de captura…
            <% is_nil(@seleccion.renglon_id) -> %>
              <span class="text-green-600 font-bold">+</span> Nueva línea
            <% true -> %>
              <span class="text-purple-600 font-bold">×</span> Renglón #{@seleccion.renglon_id}
          <% end %>
        </div>
        <div :if={@seleccion && @bloqueado?} class="text-[10px] text-amber-600 normal-case font-semibold">
          No editable en el estado actual
        </div>
        <div :if={@seleccion && !@bloqueado?} class="text-[10px] text-gray-400 normal-case">
          Enter confirma · Tab siguiente campo · F2 busca referencias · Esc cancela
        </div>
      </div>

      <%= if is_nil(@seleccion) do %>
        <div class="px-4 py-6 flex items-center justify-center text-gray-400">
          <span>Cargando…</span>
        </div>
      <% else %>
        <form id={"renglon-form-#{@cat.nombre}"} phx-hook="RenglonForm" data-catalogo={@cat.nombre} phx-change="detalle_form_cambiar">
          <input type="hidden" name="catalogo" value={@cat.nombre} />

          <div class="px-3 py-2 flex flex-wrap items-end gap-2">
            <div :for={campo <- @cat.columnas} class="flex-1 min-w-[120px]">
              <% {opciones_campo, deshabilitado_dep?, mensaje_dep} = resolver_info_dependencia(campo.schema_context_properties, opciones_para_campo(campo), &Map.get(@seleccion.valores, &1)) %>
              <.campo_input columna={campo} mostrar_etiqueta={true}
                valor={Map.get(@seleccion.valores, campo.schema_context_field, "")}
                name={"renglon[#{campo.schema_context_field}]"} opciones={opciones_campo}
                id={"campo-#{@cat.nombre}-#{campo.schema_context_field}"}
                disabled={!campo_detalle_editable?(campo, @seleccion, @campos_editables) or deshabilitado_dep?}
                mensaje_dependencia={mensaje_dep} />
            </div>
            <div class="flex items-center gap-1.5 flex-none pb-0.5">
              <button type="button" phx-click="detalle_eliminar_linea" phx-value-catalogo={@cat.nombre}
                title={
                  if @seleccion.renglon_id,
                    do: "Eliminar renglón (se aplica recién al Guardar)",
                    else: "Eliminar línea"
                }
                class="w-6 h-6 rounded-lg border border-gray-300 text-gray-600 font-bold hover:bg-gray-50">×</button>
            </div>
          </div>
        </form>
      <% end %>

      <div class="border-t border-gray-100 px-4 py-2.5 flex items-center justify-end gap-1">
        <button type="button" phx-click="detalle_navegar" phx-value-catalogo={@cat.nombre} phx-value-direccion="anterior"
          disabled={@total == 0} title="Renglón anterior"
          class="w-6 h-6 rounded-lg border border-gray-300 text-gray-600 hover:bg-gray-50 disabled:opacity-40 disabled:cursor-not-allowed">‹</button>
        <button type="button" phx-click="detalle_navegar" phx-value-catalogo={@cat.nombre} phx-value-direccion="siguiente"
          disabled={@total == 0} title="Renglón siguiente"
          class="w-6 h-6 rounded-lg border border-gray-300 text-gray-600 hover:bg-gray-50 disabled:opacity-40 disabled:cursor-not-allowed">›</button>
      </div>
    </div>
    """
  end

  # Consulta en vivo — solo se llama UNA VEZ por columna, al armar
  # cargar_catalogos_detalle/1 (mount/reload), nunca durante un render. El
  # resultado queda cacheado en `col.opciones` (ver opciones_para_campo/1
  # y campo_row/1, que leen ese campo en vez de volver a golpear la DB) —
  # antes esto corría en cada render de la Ficha 360° (cualquier evento:
  # click en fila, guardar, transición), trayendo hasta 500 filas del
  # catálogo referenciado cada vez.
  defp opciones_para_columna(%{schema_context_properties: %{"tipo" => "referencia"}} = campo),
    do: CatalogoGenerico.opciones_referencia(campo.schema_context_properties)

  defp opciones_para_columna(_campo), do: []

  defp opciones_para_campo(campo), do: Map.get(campo, :opciones, [])

  # Referencias dependientes ("combos en cascada", ver
  # MetaSchemaContext.resolver_filtros/3) — a diferencia de
  # opciones_para_columna/1 (arriba), esto SÍ corre en cada render: un
  # campo con "dependencias" no puede cachear sus opciones una sola vez
  # al mount, porque cambian con lo que el usuario va tipeando/eligiendo
  # en sus campos padre. El costo real es chico (la consulta ya viene
  # acotada por el filtro del padre, no las hasta 500 filas de
  # opciones_referencia/1 sin filtrar) y solo lo pagan los campos que
  # tienen "dependencias" configuradas — cualquier otro campo referencia
  # sigue usando `opciones_cacheadas` tal cual, cero cambio de
  # comportamiento. `buscar_valor` es un `campo -> valor | nil` que cada
  # caller arma distinto: campo_row/1 (encabezado) mezcla @edicion.valores
  # (sin guardar) con el registro persistido; formulario_renglon/1 lee
  # directo de @seleccion.valores (ya es el mapa completo del renglón).
  defp resolver_info_dependencia(props, opciones_cacheadas, buscar_valor) do
    if props["tipo"] == "referencia" and is_list(props["dependencias"]) and props["dependencias"] != [] do
      hermanos = valores_hermanos(props, buscar_valor)

      case MetaSchemaContext.resolver_filtros(props, hermanos) do
        {:ok, filtros} -> {CatalogoGenerico.opciones_referencia(props, filtros), false, nil}
        {:disabled, mensaje} -> {[], true, mensaje}
      end
    else
      {opciones_cacheadas, false, nil}
    end
  end

  defp valores_hermanos(props, buscar_valor) do
    props["dependencias"]
    |> List.wrap()
    |> Enum.map(& &1["campo_padre"])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Map.new(&{&1, buscar_valor.(&1)})
  end

  # Lee el valor real de un campo hermano del registro PERSISTIDO — a
  # diferencia del resto de este archivo (que ya conoce sus propios
  # campos), acá "campo" viene de metadata libre ("campo_padre" de una
  # dependencia, configurado a mano en el diseñador) — si apunta a un
  # campo que ya no existe (config vieja, campo borrado), no puede
  # crashear el render de la Ficha 360° entera por eso.
  defp valor_registro_seguro(registro, campo) do
    case campo_a_atom_seguro(campo) do
      {:ok, atom} -> registro |> Map.get(atom) |> valor_o_nil()
      :error -> nil
    end
  end

  defp campo_a_atom_seguro(campo) do
    {:ok, String.to_existing_atom(campo)}
  rescue
    ArgumentError -> :error
  end

  defp valor_o_nil(nil), do: nil
  defp valor_o_nil(valor), do: to_string(valor)
end
