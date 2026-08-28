defmodule MetadataAppWeb.CatalogoLive do
  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.MetaStateEngine
  alias MetadataApp.MetaConsultas
  alias MetadataApp.FiltrosDefault
  alias MetadataApp.Permissions
  alias MetadataApp.Autenticacion.Scope
  alias MetadataApp.Autenticacion.Branch
  alias MetadataApp.Autenticacion.SalesUnit
  alias MetadataApp.Autenticacion.InventoryLocation
  alias MetadataApp.Autenticacion.Empresa
  alias MetadataApp.Repo
  alias MetadataApp.MetaAuditoria
  alias MetadataApp.MetaImportacionDatos
  alias MetadataAppWeb.AdminNav
  alias MetadataAppWeb.CampoInputComponents
  import Ecto.Query

  @por_pagina 25

  # Get View unificado (ver panel_get_view/1 en BcMotorLive) — mismas 8
  # claves de control que allá, en el mismo orden de siempre (para
  # catálogos que nunca configuraron Header.orden_columnas_tabla, ver
  # construir_columnas_render/3).
  @claves_control ~w(id estado trn empresa branch inventory_location sales_unit creado_por)
  @etiquetas_control %{
    "id" => "ID",
    "estado" => "Estado",
    "trn" => "TRN",
    "empresa" => "Empresa",
    "branch" => "Sucursal",
    "inventory_location" => "Almacén",
    "sales_unit" => "Unidad de venta",
    "creado_por" => "Creado por"
  }

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
           |> put_flash(:error, "No tienes permiso para acceder a esto.")
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

    columnas = construir_columnas(header.schema_context_name)

    estados_por_id = MetaStateEngine.mapa_nombres_estados(header.schema_context_name)
    filtros = Map.merge(filtros_default_desde_columnas(columnas), filtros_por_default(header))

    mostrar_id? = header.mostrar_id_en_tabla
    mostrar_estado? = estados_por_id != %{} and header.mostrar_estado_en_tabla
    mostrar_trn? = header.schema_es_transaccional and header.mostrar_trn_en_tabla
    mostrar_empresa? = header.alcance_habilitado and header.mostrar_empresa_en_tabla
    mostrar_branch? = header.alcance_habilitado and header.mostrar_branch_en_tabla
    mostrar_inventory_location? = header.alcance_habilitado and header.mostrar_inventory_location_en_tabla
    mostrar_sales_unit? = header.alcance_habilitado and header.mostrar_sales_unit_en_tabla
    mostrar_creado_por? = header.mostrar_creado_por_en_tabla

    {bc_creado_por, campo_id_creado_por} = origen_creado_por(header, es_detalle?)

    columnas_render =
      construir_columnas_render(header, columnas, %{
        "id" => mostrar_id?,
        "estado" => mostrar_estado?,
        "trn" => mostrar_trn?,
        "empresa" => mostrar_empresa?,
        "branch" => mostrar_branch?,
        "inventory_location" => mostrar_inventory_location?,
        "sales_unit" => mostrar_sales_unit?,
        "creado_por" => mostrar_creado_por?
      })

    {:ok,
     socket
     |> assign(:current_page, header.schema_context_name)
     |> assign(:encontrado?, true)
     |> assign(:label, header.schema_context_label)
     |> assign(:columnas, columnas)
     |> assign(:columnas_render, columnas_render)
     |> assign(:mostrar_id?, mostrar_id?)
     |> assign(:mostrar_estado?, mostrar_estado?)
     |> assign(:mostrar_trn?, mostrar_trn?)
     |> assign(:mostrar_empresa?, mostrar_empresa?)
     |> assign(:mostrar_branch?, mostrar_branch?)
     |> assign(:mostrar_inventory_location?, mostrar_inventory_location?)
     |> assign(:mostrar_sales_unit?, mostrar_sales_unit?)
     |> assign(:mostrar_creado_por?, mostrar_creado_por?)
     |> assign(:bc_creado_por, bc_creado_por)
     |> assign(:campo_id_creado_por, campo_id_creado_por)
     |> assign(:modulo, modulo)
     |> assign(:header, header)
     |> assign(:es_detalle?, es_detalle?)
     |> assign(:campos_alta, campos_alta)
     # Botón "Importar" de la barra de acciones — solo visible con al menos
     # una plantilla ACTIVA (ver MetaImportacionDatos.listar_activas/1), a
     # pedido explícito: no saturar la barra de catálogos que no configuraron
     # ninguna. Un catálogo detalle nunca importa por su cuenta (Fase 1/2
     # del módulo de Importación — sus filas entran vía la plantilla del
     # maestro), así que ni se consulta.
     |> assign(:plantillas_importacion, if(es_detalle?, do: [], else: MetaImportacionDatos.listar_activas(header.id)))
     |> assign(:importar_modal, nil)
     |> allow_upload(:archivo_importacion, accept: ~w(.xlsx), max_entries: 1, auto_upload: true)
     |> assign(:estados_por_id, estados_por_id)
     |> assign(:pagina, 1)
     |> assign(:filtros, filtros)
     |> assign(:filtros_activos, campos_con_agregacion_activa(columnas))
     |> assign(:selector_campo_abierto, false)
     |> assign(:busqueda_campo_filtro, "")
     |> assign(:busqueda_general, "")
     |> assign(:mostrar_filtros, false)
     |> assign(:agregaciones, %{})
     |> assign(:agregaciones_valores, %{})
     |> assign(:minmax_valores, %{})
     |> assign(:totales_generales, %{})
     |> assign(:cargar_todos_por_default?, header.cargar_todos_por_default)
     |> assign(
       :filtro_default_fecha_descripcion,
       FiltrosDefault.descripcion(header.filtro_default_fecha_modo, header.filtro_default_fecha_valor, header.filtro_default_fecha_valor_hasta)
     )
     |> cargar_filas()}
  end

  # "Creado por" (Get View) se resuelve contra meta_schema_auditoria, nunca
  # una columna física — para un catálogo detalle usa el `bc`/id del
  # MAESTRO (quién creó el registro completo), no los del renglón mismo
  # (quién cargó esa línea puntual), a pedido explícito.
  defp origen_creado_por(header, false), do: {header.schema_context_name, :id}

  defp origen_creado_por(header, true) do
    maestro = MetaSchemaContext.obtener_header!(header.schema_encabezado_id)
    {maestro.schema_context_name, :encabezado_id}
  end

  # Combina los campos de negocio (@columnas, ya filtrados por "visible" y
  # ordenados por "orden") con los descriptores de control habilitados
  # (según los flags calculados en montar_catalogo/2) en una sola lista,
  # ordenada por Header.orden_columnas_tabla — mismo criterio que
  # filas_get_view/2 en BcMotorLive (que arma la MISMA lista pero sin
  # filtrar por visibilidad, para poder prenderla desde ahí). Lo que no
  # esté en orden_columnas_tabla cae al final (Enum.sort_by/2 es estable),
  # control primero y de negocio después — mismo orden visual que ya
  # tenía la versión vieja separada.
  defp construir_columnas_render(header, columnas, flags) do
    control =
      @claves_control
      |> Enum.filter(&Map.fetch!(flags, &1))
      |> Enum.map(fn clave ->
        %{clave: clave, etiqueta: Map.fetch!(@etiquetas_control, clave), tipo_columna: String.to_existing_atom(clave), columna: nil}
      end)

    negocio =
      Enum.map(columnas, fn c ->
        %{clave: c.schema_context_field, etiqueta: get_in(c.schema_context_properties, ["etiqueta"]), tipo_columna: :negocio, columna: c}
      end)

    # ID va antes de negocio, el resto de control después — mismo orden
    # visual que la tabla ya mostraba antes de este Get View unificado
    # (id | campos de negocio | estado/trn/empresa/... ), para no romper
    # ningún catálogo ya publicado que nunca configuró orden_columnas_tabla.
    {id_control, resto_control} = Enum.split_with(control, &(&1.clave == "id"))
    todas = id_control ++ negocio ++ resto_control

    case header.orden_columnas_tabla do
      [] ->
        todas

      orden ->
        indice = orden |> Enum.with_index() |> Map.new()
        Enum.sort_by(todas, &Map.get(indice, &1.clave, map_size(indice)))
    end
  end

  defp construir_columnas(schema_context_name) do
    schema_context_name
    |> MetaSchemaContext.listar_detalles()
    |> Enum.map(&MetaSchemaContext.serializar_detalle/1)
    |> Enum.filter(&get_in(&1, [:schema_context_properties, "visible"]))
    |> Enum.sort_by(&get_in(&1, [:schema_context_properties, "orden"]))
  end

  # Get View → "Filtros" (bc_motor_live.ex, panel_filtros_resumen/1) — los
  # campos que el admin agregó ahí (participan del Resumen) arrancan como
  # filas YA VISIBLES en el popover de Filtros del usuario final
  # (panel_filtros/1 acá abajo), sin que tenga que buscarlos a mano con
  # "+ Agregar filtro". La fila arranca vacía salvo que el admin también
  # haya puesto un "Valor por default" (ver filtros_default_desde_columnas/1
  # abajo) — ahí sí arranca con ese valor puesto Y aplicado de una.
  defp campos_con_agregacion_activa(columnas) do
    columnas
    |> Enum.filter(&get_in(&1, [:schema_context_properties, "agregacion_activa"]))
    |> Enum.map(& &1.schema_context_field)
  end

  # "Valor por default" de un filtro (bc_motor_live.ex, mismo panel que
  # arriba) — a diferencia de "Filtros por default" (filtros_por_default/1,
  # una sola fecha de ALTA global), esto es por CAMPO: boolean/string/enum
  # guardan un solo valor ("filtro_default_valor", mismo formato que
  # @filtros[campo] ya espera), integer/decimal/date guardan un rango
  # ("filtro_default_desde"/"_hasta", formato "#{campo}_desde"/"_hasta").
  # El resultado se mergea directo en @filtros inicial — no es una fila
  # vacía esperando que alguien tipee, ya arranca filtrando de verdad.
  defp filtros_default_desde_columnas(columnas) do
    Enum.reduce(columnas, %{}, fn columna, acc ->
      props = columna.schema_context_properties
      campo = columna.schema_context_field

      case props["tipo"] do
        tipo when tipo in ["integer", "decimal", "date"] ->
          acc
          |> poner_si_hay_valor("#{campo}_desde", props["filtro_default_desde"])
          |> poner_si_hay_valor("#{campo}_hasta", props["filtro_default_hasta"])

        _tipo ->
          poner_si_hay_valor(acc, campo, props["filtro_default_valor"])
      end
    end)
  end

  defp poner_si_hay_valor(acc, _clave, nil), do: acc
  defp poner_si_hay_valor(acc, _clave, ""), do: acc
  defp poner_si_hay_valor(acc, clave, valor), do: Map.put(acc, clave, valor)

  # Get View → "Filtros por default" (bc_motor_live.ex): "Agregar todos
  # los registros" + acotar por fecha de alta — arma el @filtros INICIAL
  # de la tabla, en vez de arrancar vacía. Filtra directo sobre la
  # columna real "fecha_registro" (2026-08-06, en TODA tabla de catálogo
  # — ver MetaCatalogoGenerico) — antes de que existiera, esto resolvía
  # la fecha vía la tabla de auditoría (MetaAuditoria.ids_creados_en_rango/3,
  # ya no hace falta). Va aparte como "__fecha_registro__" (no es una
  # fila editable del panel de Filtros normal, así que no puede sumarse
  # a @filtros con la clave "fecha_registro_desde"/"_hasta" de siempre —
  # eso dejaría ver/tocar un input que no existe en el panel).
  defp filtros_por_default(header) do
    case FiltrosDefault.rango_fecha(header.filtro_default_fecha_modo, header.filtro_default_fecha_valor, header.filtro_default_fecha_valor_hasta) do
      nil -> %{}
      {desde, hasta} -> %{"__fecha_registro__" => {desde, hasta}}
    end
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
     |> assign(:agregaciones, %{})
     |> assign(:agregaciones_valores, %{})
     |> assign(:minmax_valores, %{})
     |> assign(:totales_generales, %{})
     |> assign(:cargar_todos_por_default?, false)
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

  # --- Asistente "Importar" (Fase 1 del módulo de Importación) -------------
  # Paso 1: elegir plantilla · Paso 2: descargar/subir el Excel · Paso 3:
  # ver la previsualización (dry-run, nada persistido todavía) · Paso 4:
  # confirmar y ejecutar de verdad. Reusa MetaImportacionDatos.previsualizar/3
  # y ejecutar/3 tal cual — este LiveView no valida nada por su cuenta.

  def handle_event("abrir_importar", _params, socket) do
    {:noreply, assign(socket, :importar_modal, %{"paso" => 1, "plantilla_id" => nil, "filas_leidas" => nil, "resultado" => nil, "error" => nil})}
  end

  def handle_event("cerrar_importar", _params, socket) do
    {:noreply, assign(socket, :importar_modal, nil)}
  end

  def handle_event("importar_elegir_plantilla", %{"id" => id}, socket) do
    modal = %{
      socket.assigns.importar_modal
      | "paso" => 2,
        "plantilla_id" => String.to_integer(id),
        "filas_leidas" => nil,
        "resultado" => nil,
        "error" => nil
    }

    {:noreply, assign(socket, :importar_modal, modal)}
  end

  def handle_event("importar_volver", _params, socket) do
    modal = %{socket.assigns.importar_modal | "paso" => 1, "plantilla_id" => nil, "filas_leidas" => nil, "resultado" => nil, "error" => nil}
    {:noreply, assign(socket, :importar_modal, modal)}
  end

  # Requerido por <.live_file_input> (LiveView necesita un phx-change en el
  # form que lo contiene para trackear selección/progreso) — nada que
  # validar acá, la lectura real recién pasa al "Subir y validar".
  def handle_event("importar_archivo_seleccionado", _params, socket), do: {:noreply, socket}

  def handle_event("importar_procesar_archivo", _params, socket) do
    modal = socket.assigns.importar_modal
    plantilla = MetaImportacionDatos.obtener_plantilla!(modal["plantilla_id"])

    resultados =
      consume_uploaded_entries(socket, :archivo_importacion, fn %{path: path}, _entry ->
        {:ok, MetaImportacionDatos.leer_excel(path, plantilla)}
      end)

    case resultados do
      [{:ok, %{"encabezado" => []}}] ->
        {:noreply, assign(socket, :importar_modal, Map.put(modal, "error", "El archivo no tiene ninguna fila de datos para importar."))}

      [{:ok, filas}] ->
        resultado = MetaImportacionDatos.previsualizar(plantilla, socket.assigns.current_scope, filas)

        modal = %{modal | "paso" => 3, "filas_leidas" => filas, "resultado" => resultado, "error" => nil}
        {:noreply, assign(socket, :importar_modal, modal)}

      [{:error, motivo}] ->
        {:noreply, assign(socket, :importar_modal, Map.put(modal, "error", "No se pudo leer el archivo: #{motivo}"))}

      [] ->
        {:noreply, assign(socket, :importar_modal, Map.put(modal, "error", "Elegí un archivo .xlsx para subir."))}
    end
  end

  def handle_event("importar_confirmar", _params, socket) do
    modal = socket.assigns.importar_modal
    plantilla = MetaImportacionDatos.obtener_plantilla!(modal["plantilla_id"])
    resultado = MetaImportacionDatos.ejecutar(plantilla, socket.assigns.current_scope, modal["filas_leidas"])

    modal = %{modal | "paso" => 4, "resultado" => resultado}
    {:noreply, socket |> assign(:importar_modal, modal) |> assign(:pagina, 1) |> cargar_filas()}
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

  # Un filtro "Bloqueado" (bc_motor_live.ex) sobrevive a "Limpiar filtros"
  # — el usuario final puede vaciar TODO lo que agregó a mano, pero no lo
  # que el admin dejó fijo.
  def handle_event("limpiar_filtros", _params, socket) do
    filtros = preservar_filtros_bloqueados(socket.assigns.filtros, socket.assigns.columnas)
    {:noreply, socket |> assign(:filtros, filtros) |> assign(:pagina, 1) |> cargar_filas()}
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
  # panel pero la query seguiría acotada por él). No-op si el campo está
  # "Bloqueado" (bc_motor_live.ex) — el botón "Quitar" ni se muestra para
  # esos en el popover, pero este guard cubre igual un evento disparado a
  # mano (ej. devtools).
  def handle_event("quitar_filtro_campo", %{"campo" => campo}, socket) do
    if campo_bloqueado?(socket.assigns.columnas, campo) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:filtros_activos, List.delete(socket.assigns.filtros_activos, campo))
       |> assign(:filtros, quitar_valores_filtro(socket.assigns.filtros, campo))
       |> assign(:pagina, 1)
       |> cargar_filas()}
    end
  end

  # "Resumen" (fila de pie de tabla, ver celdas_resumen/1) — funcion=""
  # (opción "—" del <select>) quita la columna del resumen en
  # vez de guardar una función vacía. Recalcula TODAS las agregaciones
  # activas, no solo la que cambió — barato (son cuantas columnas el
  # usuario haya elegido, nunca todas), y evita un segundo código path
  # para "ya tengo el valor pero necesito refrescarlo".
  def handle_event("cambiar_agregacion", %{"campo" => campo, "funcion" => ""}, socket) do
    {:noreply,
     socket
     |> assign(:agregaciones, Map.delete(socket.assigns.agregaciones, campo))
     |> recalcular_agregaciones()}
  end

  def handle_event("cambiar_agregacion", %{"campo" => campo, "funcion" => funcion}, socket) do
    {:noreply,
     socket
     |> assign(:agregaciones, Map.put(socket.assigns.agregaciones, campo, funcion))
     |> recalcular_agregaciones()}
  end

  # Paginación real por SQL (limit/offset en la query, no traer todo y
  # cortar en el LiveView) — a diferencia de BcListLive, que pagina en
  # memoria porque ahí son decenas de Business Contexts, no potencialmente
  # miles de filas de datos de un catálogo real.
  #
  # La tabla NO trae datos hasta que haya al menos un filtro de columna
  # con valor real o texto en el buscador general — evita traer TODO el
  # catálogo (potencialmente miles de filas) apenas se abre la página.
  # Una vez que hay filtro/búsqueda, pagina normal sobre ESE subconjunto.
  defp cargar_filas(socket) do
    socket = assign(socket, :sin_filtro?, not datos_solicitados?(socket))

    if socket.assigns.sin_filtro? do
      socket |> vaciar_filas() |> recalcular_agregaciones() |> recalcular_minmax() |> recalcular_totales_generales()
    else
      socket |> cargar_filas_real() |> recalcular_agregaciones() |> recalcular_minmax() |> recalcular_totales_generales()
    end
  end

  defp datos_solicitados?(socket) do
    socket.assigns.cargar_todos_por_default? or
      Map.has_key?(socket.assigns.filtros, "__fecha_registro__") or
      contar_filtros_activos(socket.assigns.filtros) > 0 or
      String.trim(socket.assigns.busqueda_general) != ""
  end

  defp cargar_filas_real(%{assigns: %{es_consulta?: true}} = socket), do: cargar_filas_consulta(socket)
  defp cargar_filas_real(socket), do: cargar_filas_catalogo(socket)

  defp vaciar_filas(%{assigns: %{es_consulta?: true}} = socket) do
    socket
    |> assign(:filas, [])
    |> assign(:totales, %{})
    |> assign(:pagina, 1)
    |> assign(:total_paginas, 1)
    |> assign(:total_filas, 0)
    |> assign(:inicio, 0)
    |> assign(:fin, 0)
  end

  defp vaciar_filas(socket) do
    socket
    |> assign(:filas, [])
    |> assign(:pagina, 1)
    |> assign(:total_paginas, 1)
    |> assign(:total_filas, 0)
    |> assign(:inicio, 0)
    |> assign(:fin, 0)
  end

  defp filtros_y_busqueda(socket) do
    %{filtros: filtros, columnas: columnas, busqueda_general: busqueda_general} = socket.assigns
    filtros_ecto = construir_filtros_ecto(filtros, columnas)
    campos_busqueda = Enum.map(columnas, & &1.schema_context_field)
    {filtros_ecto, {busqueda_general, campos_busqueda}}
  end

  # Recalcula el VALOR de cada columna con una función de agregación
  # elegida (ver @agregaciones) contra los filtros/búsqueda ACTUALES —
  # se llama tanto al cambiar la función de una columna como cada vez que
  # cargar_filas/1 corre (filtro, búsqueda o página nueva), para que el
  # resumen nunca quede desactualizado respecto de lo que se está viendo.
  # No cuesta nada si @agregaciones está vacío (nadie eligió ninguna
  # todavía) — Map.new de un mapa vacío es instantáneo, cero queries.
  defp recalcular_agregaciones(socket) do
    {filtros_ecto, busqueda} = filtros_y_busqueda(socket)

    valores =
      Map.new(socket.assigns.agregaciones, fn {campo, funcion} ->
        {campo, calcular_agregacion(socket, campo, funcion, filtros_ecto, busqueda)}
      end)

    assign(socket, :agregaciones_valores, valores)
  end

  # Mismo criterio que recalcular_agregaciones/1 pero para "Filtros Min."
  # (ver celdas_resumen/1) — a diferencia de @agregaciones, que el usuario
  # final elige por columna, acá no hay elección: cada columna NUMÉRICA
  # con "minmax_recomendado" en el Get View (ver panel_get_view/1 en
  # bc_motor_live.ex) SIEMPRE muestra su {mínimo, máximo}, calculado de
  # una. Restringido a integer/decimal a propósito (igual que "Total
  # 25"/"Totalizado") — el botón para prenderlo ni se muestra para otros
  # tipos.
  defp recalcular_minmax(socket) do
    {filtros_ecto, busqueda} = filtros_y_busqueda(socket)

    columnas_minmax =
      Enum.filter(socket.assigns.columnas, fn columna ->
        columna.schema_context_properties["tipo"] in ["integer", "decimal"] and
          columna.schema_context_properties["minmax_recomendado"] == true
      end)

    valores =
      Map.new(columnas_minmax, fn columna ->
        clave = col_key(columna)
        minimo = calcular_agregacion(socket, clave, "minimo", filtros_ecto, busqueda)
        maximo = calcular_agregacion(socket, clave, "maximo", filtros_ecto, busqueda)
        {clave, {minimo, maximo}}
      end)

    assign(socket, :minmax_valores, valores)
  end

  # Mismo criterio que recalcular_minmax/1 pero para "Totalizado" (Get
  # View → Filtros → "Totalizado", bc_motor_live.ex): suma de TODOS los
  # registros que matchean filtro/búsqueda, no solo la página actual (a
  # diferencia de "Total 25" — ver total_columna_pagina/2 — que no
  # necesita query nueva porque suma directo sobre @filas ya cargadas).
  defp recalcular_totales_generales(socket) do
    {filtros_ecto, busqueda} = filtros_y_busqueda(socket)

    columnas_total_general =
      Enum.filter(socket.assigns.columnas, &(&1.schema_context_properties["total_general_activo"] == true))

    valores =
      Map.new(columnas_total_general, fn columna ->
        clave = col_key(columna)
        {clave, calcular_agregacion(socket, clave, "suma", filtros_ecto, busqueda)}
      end)

    assign(socket, :totales_generales, valores)
  end

  defp calcular_agregacion(%{assigns: %{es_consulta?: true, consulta: consulta}}, campo, funcion, filtros_ecto, busqueda) do
    MetaConsultas.agregar(consulta, campo, funcion_agregada(funcion), filtros_ecto, busqueda)
  end

  defp calcular_agregacion(%{assigns: %{modulo: nil}}, _campo, _funcion, _filtros_ecto, _busqueda), do: nil

  defp calcular_agregacion(%{assigns: %{modulo: modulo} = assigns}, campo, funcion, filtros_ecto, busqueda) do
    CatalogoGenerico.agregar(modulo, assigns[:current_scope], campo, funcion_agregada(funcion), filtros_ecto, busqueda)
  end

  defp funcion_agregada("suma"), do: :sum
  defp funcion_agregada("promedio"), do: :avg
  defp funcion_agregada("minimo"), do: :min
  defp funcion_agregada("maximo"), do: :max
  defp funcion_agregada("conteo"), do: :count

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

      total_filas = CatalogoGenerico.contar(modulo, socket.assigns[:current_scope], filtros_ecto, busqueda)
      total_paginas = max(ceil(total_filas / @por_pagina), 1)
      pagina = socket.assigns.pagina |> max(1) |> min(total_paginas)
      offset = (pagina - 1) * @por_pagina

      registros =
        CatalogoGenerico.listar(modulo, socket.assigns[:current_scope], filtros_ecto, [limit: @por_pagina, offset: offset], busqueda)
      acompanamiento = CatalogoGenerico.mapa_acompanamiento(catalogo, registros)

      filas =
        registros
        |> Enum.map(&CatalogoGenerico.serializar(&1, estados_por_id, acompanamiento))
        |> agregar_alcance_a_filas(socket.assigns)
        |> agregar_creado_por_a_filas(socket.assigns)

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

  # Columnas de Alcance de Datos (2026-08-12) — mismo criterio batch-por-
  # página que mapa_acompanamiento/2 de CatalogoGenerico (nunca una query
  # por fila): junta los ids que de verdad aparecen en ESTA página,
  # resuelve nombre en 3 queries chicas (branch/sales_unit/inventory) más
  # una cuarta para Empresa (encadenada desde branch_id -> Branch.empresa_id,
  # no hay columna empresa_id propia en la fila -- ver moduledoc de
  # CatalogoGenerador.columnas_alcance/1). Si ninguna de las 4 columnas
  # está habilitada para mostrarse, no pega ninguna query de más.
  defp agregar_alcance_a_filas(filas, %{mostrar_empresa?: false, mostrar_branch?: false, mostrar_inventory_location?: false, mostrar_sales_unit?: false}),
    do: filas

  defp agregar_alcance_a_filas(filas, _assigns) do
    branch_ids = ids_unicos(filas, :branch_id)
    sales_unit_ids = ids_unicos(filas, :sales_unit_id)
    inventory_ids = ids_unicos(filas, :inventory_id)

    branches =
      if branch_ids == [], do: [], else: Repo.all(from(b in Branch, where: b.id in ^branch_ids, select: {b.id, b.branch_name, b.empresa_id}))

    branch_nombre_por_id = Map.new(branches, fn {id, nombre, _empresa_id} -> {id, nombre} end)
    empresa_id_por_branch = Map.new(branches, fn {id, _nombre, empresa_id} -> {id, empresa_id} end)
    empresa_ids = empresa_id_por_branch |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.uniq()

    empresa_nombre_por_id =
      if empresa_ids == [], do: %{}, else: Repo.all(from(e in Empresa, where: e.id in ^empresa_ids, select: {e.id, e.nombre})) |> Map.new()

    sales_unit_nombre_por_id =
      if sales_unit_ids == [], do: %{}, else: Repo.all(from(s in SalesUnit, where: s.id in ^sales_unit_ids, select: {s.id, s.sales_unit_name})) |> Map.new()

    inventory_nombre_por_id =
      if inventory_ids == [], do: %{}, else: Repo.all(from(i in InventoryLocation, where: i.id in ^inventory_ids, select: {i.id, i.inventory_name})) |> Map.new()

    Enum.map(filas, fn fila ->
      branch_id = Map.get(fila, :branch_id)
      empresa_id = branch_id && Map.get(empresa_id_por_branch, branch_id)
      sales_unit_id = Map.get(fila, :sales_unit_id)
      inventory_id = Map.get(fila, :inventory_id)

      fila
      |> Map.put(:branch_nombre, branch_id && Map.get(branch_nombre_por_id, branch_id))
      |> Map.put(:sales_unit_nombre, sales_unit_id && Map.get(sales_unit_nombre_por_id, sales_unit_id))
      |> Map.put(:inventory_nombre, inventory_id && Map.get(inventory_nombre_por_id, inventory_id))
      |> Map.put(:empresa_nombre, empresa_id && Map.get(empresa_nombre_por_id, empresa_id))
    end)
  end

  defp ids_unicos(filas, campo), do: filas |> Enum.map(&Map.get(&1, campo)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  # "Creado por" (Get View) — mismo criterio batch-por-página que
  # agregar_alcance_a_filas/2 de arriba (una sola consulta a
  # meta_schema_auditoria, nunca una por fila). `bc_creado_por`/
  # `campo_id_creado_por` ya vienen resueltos desde montar_catalogo/2
  # (origen_creado_por/2) — acá no hay que saber de nuevo si el catálogo
  # es detalle o no.
  defp agregar_creado_por_a_filas(filas, %{mostrar_creado_por?: false}), do: filas

  defp agregar_creado_por_a_filas(filas, %{bc_creado_por: bc, campo_id_creado_por: campo}) do
    ids = ids_unicos(filas, campo)
    creadores = MetaAuditoria.creadores_de(bc, ids)

    Enum.map(filas, &Map.put(&1, :creado_por, Map.get(creadores, Map.get(&1, campo))))
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
    base =
      Enum.reduce(columnas, %{}, fn columna, acc ->
        campo = columna.schema_context_field
        tipo = columna.schema_context_properties["tipo"]
        agregar_filtro_ecto(acc, campo, tipo, filtros)
      end)

    # "__fecha_registro__" (ver filtros_por_default/1) — mismo campo real
    # "fecha_registro" que ya procesó el reduce de arriba (si el usuario
    # final lo agregó a mano desde el panel de Filtros normal), pero con
    # su PROPIA clave para no pisarse con "fecha_registro_desde"/"_hasta"
    # ni viceversa — son dos filtros independientes sobre la misma
    # columna, el de acá con bordes de DateTime completos (00:00:00 a
    # 23:59:59) en vez de un %Date{} suelto.
    case Map.get(filtros, "__fecha_registro__") do
      nil -> base
      {desde, hasta} -> Map.put(base, :fecha_registro, {:entre, {desde, hasta}})
    end
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

  # "enum"/"referencia" tienen un <select> dedicado (ver filtro_columna/1 y
  # fila_filtro_columna/1) — a diferencia del catch-all de abajo, acá el
  # valor es una coincidencia EXACTA (código del enum / id de la fila
  # referenciada), no un substring vía ILIKE.
  defp agregar_filtro_ecto(acc, campo, "enum", filtros) do
    case Map.get(filtros, campo) |> valor_no_vacio() do
      nil -> acc
      valor -> Map.put(acc, campo, valor)
    end
  end

  defp agregar_filtro_ecto(acc, campo, "referencia", filtros) do
    case Map.get(filtros, campo) |> valor_no_vacio() |> convertir("referencia") do
      nil -> acc
      valor -> Map.put(acc, campo, valor)
    end
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

  defp campo_bloqueado?(columnas, campo) do
    case Enum.find(columnas, &(&1.schema_context_field == campo)) do
      nil -> false
      columna -> columna.schema_context_properties["filtro_default_bloqueado"] == true
    end
  end

  # "Limpiar filtros" vacía @filtros por completo salvo las claves que
  # pertenecen a un campo "Bloqueado" — esas se copian tal cual del estado
  # actual (nunca cambiaron, porque su input es un <input type="hidden">,
  # ver filtro_columna/1).
  defp preservar_filtros_bloqueados(filtros, columnas) do
    campos_bloqueados =
      columnas
      |> Enum.filter(&(&1.schema_context_properties["filtro_default_bloqueado"] == true))
      |> Enum.map(& &1.schema_context_field)

    Enum.reduce(filtros, %{}, fn {clave, valor}, acc ->
      campo_base = clave |> String.replace_trailing("_desde", "") |> String.replace_trailing("_hasta", "")
      if campo_base in campos_bloqueados, do: Map.put(acc, clave, valor), else: acc
    end)
  end

  # Cuenta campos con un valor realmente puesto (no solo agregados al panel
  # pero todavía vacíos) — un rango cuenta una sola vez aunque tenga
  # _desde/_hasta. Usado para el badge del botón "Filtros". Ignora claves
  # internas tipo "__fecha_registro__" (filtro por default de fecha, ver
  # filtros_por_default/1) — no es una fila real del panel, no debe sumar
  # al contador que ve el usuario final.
  defp contar_filtros_activos(filtros) do
    filtros
    |> Enum.reject(fn {campo, valor} -> valor in [nil, ""] or String.starts_with?(campo, "__") end)
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
  defp convertir(v, "referencia"), do: parsear(fn -> String.to_integer(v) end)

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

        <form id="form-filtros" phx-change="filtrar" class="hidden" aria-hidden="true"></form>

        <div class="flex flex-col gap-2 mb-4 sm:flex-row sm:items-center">
          <div class="relative sm:flex-1">
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
          <div class="flex items-center gap-2">
            <div class="relative flex-1 sm:flex-none">
              <button
                type="button"
                phx-click="abrir_filtros"
                class={[
                  "flex items-center justify-center gap-1.5 border rounded-lg px-3 py-2 text-sm font-semibold whitespace-nowrap transition-colors w-full sm:w-auto",
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
        </div>

        <div class="overflow-x-auto rounded-xl border border-gray-200">
          <table id="tabla-catalogo" class="min-w-full divide-y divide-gray-200 text-xs">
            <thead class="bg-gray-50">
              <tr>
                <%= for columna <- @columnas do %>
                  <th
                    data-col={col_key(columna)}
                    title={if @consulta.joins != [], do: "De: #{columna.catalogo}"}
                    class={["px-2 py-3 sm:px-4 text-xs font-semibold text-gray-500 uppercase tracking-wide whitespace-nowrap", alineacion_columna(columna)]}
                  >
                    {columna.schema_context_properties["etiqueta"]}
                  </th>
                <% end %>
              </tr>
              <tr class="bg-gray-50/60 border-t border-gray-100">
                <.fila_filtros_columnas columnas={@columnas} filtros={@filtros} />
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <%= for fila <- @filas do %>
                <tr class="hover:bg-purple-50/60 transition-colors">
                  <%= for columna <- @columnas do %>
                    <% valor = Map.get(fila, columna.clave) %>
                    <td data-col={col_key(columna)} class={[
                      "px-2 py-2 text-[11px] sm:px-4 sm:py-1.5 sm:text-[10px] text-gray-700",
                      alineacion_columna(columna)
                    ]}>
                      {formatear_celda(valor, columna.schema_context_properties)}
                    </td>
                  <% end %>
                </tr>
              <% end %>
              <%= if @filas == [] do %>
                <tr>
                  <td class="px-4 py-10 text-center text-gray-400 text-sm" colspan={max(length(@columnas), 1)}>
                    <%= if @sin_filtro? do %>
                      Seleccioná un filtro o buscá algo para ver los datos.
                    <% else %>
                      Sin registros con ese filtro.
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
            <tfoot :if={@totales != %{}} class="bg-purple-50 border-t-2 border-purple-200 font-bold">
              <tr>
                <%= for columna <- @columnas do %>
                  <td data-col={col_key(columna)} class={["px-4 py-2 text-[10px] text-purple-900", alineacion_columna(columna)]}>
                    <%= if Map.get(columna, :totalizar) do %>
                      {formatear_celda(Map.get(@totales, columna.clave), columna.schema_context_properties)}
                    <% end %>
                  </td>
                <% end %>
              </tr>
            </tfoot>
            <tfoot class="bg-gray-50 border-t-2 border-gray-300">
              <tr>
                <.celdas_resumen
                  columnas={@columnas}
                  agregaciones={@agregaciones}
                  valores={@agregaciones_valores}
                  minmax_valores={@minmax_valores}
                  totales_generales={@totales_generales}
                  filas={@filas}
                  es_consulta?={@es_consulta?}
                />
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
      <%!-- bottom-20/right-3, no bottom-5/right-5: el botón flotante de
      .pc-footer-toggle-btn (menu.css, "mostrar/ocultar barra inferior")
      ya vive fixed bottom:12px/right:12px en mobile -- con menos separación
      quedaban los dos círculos superpuestos en la misma esquina. --%>
      <.link :if={@campos_alta != []} navigate={"/registro/#{@current_page}/nuevo"}
        aria-label="Nuevo registro"
        class="sm:hidden fixed bottom-20 right-3 z-30 flex items-center justify-center w-14 h-14 rounded-full bg-purple-600 text-white shadow-lg shadow-purple-600/30 hover:bg-purple-700 active:scale-95 transition">
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" />
        </svg>
      </.link>
      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-5">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-4">
          <h1 class="text-xl font-bold text-gray-900">{@label}</h1>

          <div class="flex items-center gap-2 flex-wrap">
            <.link :if={@campos_alta != []} navigate={"/registro/#{@current_page}/nuevo"}
              aria-label="Nuevo registro"
              class="hidden sm:flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                <line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" />
              </svg>
              <span>Nuevo registro</span>
            </.link>
            <button :if={@plantillas_importacion != []} type="button" phx-click="abrir_importar"
              class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 text-xs font-semibold hover:bg-gray-50">
              <span class="material-symbols-outlined" style="font-size:14px">upload_file</span>
              <span>Importar</span>
            </button>
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

        <form id="form-filtros" phx-change="filtrar" class="hidden" aria-hidden="true"></form>

        <div class="flex flex-col gap-2 mb-4 sm:flex-row sm:items-center">
          <div class="relative sm:flex-1">
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
          <div class="flex items-center gap-2">
            <div class="relative flex-1 sm:flex-none">
              <button
                type="button"
                phx-click="abrir_filtros"
                class={[
                  "flex items-center justify-center gap-1.5 border rounded-lg px-3 py-2 text-sm font-semibold whitespace-nowrap transition-colors w-full sm:w-auto",
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
            <.panel_campos campos={campos_selector_render(@columnas_render)} tabla_id="tabla-catalogo" />
          </div>
        </div>

        <div :if={@filtro_default_fecha_descripcion} class="flex items-center gap-1.5 text-[11px] font-medium text-purple-700 bg-purple-50 border border-purple-200 rounded-lg px-2.5 py-1.5 mb-4 w-fit">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="shrink-0">
            <rect x="3" y="4" width="18" height="18" rx="2" ry="2" /><line x1="16" y1="2" x2="16" y2="6" /><line x1="8" y1="2" x2="8" y2="6" /><line x1="3" y1="10" x2="21" y2="10" />
          </svg>
          {@filtro_default_fecha_descripcion}
        </div>

        <div class="overflow-x-auto rounded-xl border border-gray-200">
          <table id="tabla-catalogo" class="min-w-full divide-y divide-gray-200 text-xs">
            <thead class="bg-gray-50">
              <tr>
                <.celda_encabezado :for={col <- @columnas_render} col={col} />
                <th class="px-2 py-3 sm:px-4 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide whitespace-nowrap"></th>
              </tr>
              <tr class="bg-gray-50/60 border-t border-gray-100">
                <.celda_filtro :for={col <- @columnas_render} col={col} filtros={@filtros} />
                <th class="px-2 py-1.5 sm:px-4"></th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <%= for fila <- @filas do %>
                <tr class="hover:bg-purple-50/60 transition-colors cursor-pointer"
                  ondblclick={"window.location='/registro/#{@current_page}/#{fila.id}'"}
                  onclick={"if (window.matchMedia('(pointer: coarse)').matches && !event.target.closest('a')) { window.location='/registro/#{@current_page}/#{fila.id}' }"}>
                  <.celda_body :for={col <- @columnas_render} col={col} fila={fila} />
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
                  <td class="px-4 py-10 text-center text-gray-400 text-sm" colspan={length(@columnas_render) + 1}>
                    <%= if @sin_filtro? do %>
                      Seleccioná un filtro o buscá algo para ver los datos.
                    <% else %>
                      Sin registros con ese filtro.
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
            <tfoot class="bg-gray-50 border-t-2 border-gray-300">
              <tr>
                <.celda_resumen_col
                  :for={col <- @columnas_render}
                  col={col}
                  agregaciones={@agregaciones}
                  valores={@agregaciones_valores}
                  minmax_valores={@minmax_valores}
                  totales_generales={@totales_generales}
                  filas={@filas}
                />
                <td></td>
              </tr>
            </tfoot>
          </table>
        </div>
      </div>

      <.modal_importar :if={@importar_modal} modal={@importar_modal} plantillas={@plantillas_importacion} uploads={@uploads} />
    </div>
    """
  end

  attr :modal, :map, required: true
  attr :plantillas, :list, required: true
  attr :uploads, :map, required: true

  defp modal_importar(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-xl w-full text-xs max-h-[90vh] overflow-y-auto">
        <div class="px-4 pt-4 pb-3 border-b border-gray-100 flex items-start justify-between gap-3">
          <div class="flex items-start gap-2.5">
            <span class="material-symbols-outlined text-purple-600 mt-0.5" style="font-size:20px">upload_file</span>
            <div>
              <h2 class="text-sm font-bold text-gray-900">Importar registros</h2>
              <p class="text-gray-500 mt-0.5">Descargá la plantilla, llenala y subila — validamos antes de confirmar.</p>
            </div>
          </div>
          <button type="button" phx-click="cerrar_importar" class="text-gray-400 hover:text-gray-700 flex-shrink-0">
            <span class="material-symbols-outlined" style="font-size:20px">close</span>
          </button>
        </div>

        <div class="p-4">
          <div :if={@modal["error"]} class="bg-red-50 text-red-700 rounded-lg px-2.5 py-1.5 mb-3">{@modal["error"]}</div>

          <%= if @modal["paso"] == 1 do %>
            <p class="text-gray-500 mb-2">Elegí qué plantilla vas a usar:</p>
            <div class="flex flex-col gap-2">
              <button :for={p <- @plantillas} type="button" phx-click="importar_elegir_plantilla" phx-value-id={p.id}
                class="text-left border border-gray-200 rounded-lg px-3 py-2 hover:border-purple-400 hover:bg-purple-50">
                <div class="font-semibold text-gray-900">{p.nombre}</div>
                <div :if={p.descripcion} class="text-gray-500">{p.descripcion}</div>
              </button>
            </div>
          <% end %>

          <%= if @modal["paso"] == 2 do %>
            <% plantilla_elegida = Enum.find(@plantillas, &(&1.id == @modal["plantilla_id"])) %>
            <p class="text-gray-600 mb-2">
              <%!-- target="_blank" a propósito (bug real reportado): un <a href>
                   normal hace que LiveView detecte "va a navegar" y mate el
                   socket de ESTA página ANTES de saber que la respuesta es una
                   descarga de archivo (Content-Disposition: attachment), no una
                   navegación real -- "Subir y validar" quedaba mudo después,
                   sin ningún error visible, porque el socket ya estaba muerto.
                   Abrir en pestaña nueva nunca toca el socket de acá. --%>
              1. <.link href={~p"/sysadmin/importacion/#{@modal["plantilla_id"]}/descargar"} target="_blank" class="text-purple-700 font-semibold hover:underline">Descargá la plantilla "{plantilla_elegida.nombre}"</.link>,
              llenala con los datos y subila acá abajo.
            </p>
            <p class="text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 mb-3">
              La fila 2 (en cursiva/gris) es solo un ejemplo — no la edites. Agregá tus registros a partir de la fila 3.
            </p>
            <form id="form-importar-archivo" phx-submit="importar_procesar_archivo" phx-change="importar_archivo_seleccionado" class="border border-dashed border-gray-300 rounded-lg p-4">
              <.live_file_input upload={@uploads.archivo_importacion} />
              <div :for={entry <- @uploads.archivo_importacion.entries} class="mt-2 flex items-center gap-2">
                <span class="text-gray-600">{entry.client_name}</span>
                <progress value={entry.progress} max="100" class="flex-1 h-1.5">{entry.progress}%</progress>
              </div>
              <div class="flex justify-between mt-3">
                <button type="button" phx-click="importar_volver" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
                  ← Volver
                </button>
                <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">
                  Subir y validar
                </button>
              </div>
            </form>
          <% end %>

          <%= if @modal["paso"] == 3 do %>
            <.resultado_importar resultado={@modal["resultado"]} confirmando?={false} />
            <div class="flex justify-between mt-3">
              <button type="button" phx-click="importar_volver" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
                ← Elegir otro archivo
              </button>
              <button type="button" phx-click="importar_confirmar"
                disabled={Enum.all?(@modal["resultado"], &(&1.resultado == :error))}
                class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 disabled:opacity-40 disabled:cursor-not-allowed">
                Confirmar importación
              </button>
            </div>
          <% end %>

          <%= if @modal["paso"] == 4 do %>
            <.resultado_importar resultado={@modal["resultado"]} confirmando?={true} />
            <div class="flex justify-end mt-3">
              <button type="button" phx-click="cerrar_importar" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">
                Cerrar
              </button>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :resultado, :list, required: true
  attr :confirmando?, :boolean, required: true

  defp resultado_importar(assigns) do
    ok = Enum.count(assigns.resultado, &(&1.resultado == :ok))
    error = Enum.count(assigns.resultado, &(&1.resultado == :error))
    assigns = assigns |> assign(:ok, ok) |> assign(:error, error)

    ~H"""
    <div class="flex items-center gap-3 mb-3">
      <span class="inline-flex items-center gap-1 px-2 py-1 rounded-lg bg-green-50 text-green-700 font-semibold">
        <span class="material-symbols-outlined" style="font-size:14px">check_circle</span>
        {@ok} {if @confirmando?, do: "creados", else: "listos para crear"}
      </span>
      <span :if={@error > 0} class="inline-flex items-center gap-1 px-2 py-1 rounded-lg bg-red-50 text-red-700 font-semibold">
        <span class="material-symbols-outlined" style="font-size:14px">error</span>
        {@error} con error
      </span>
    </div>

    <div :if={@error > 0} class="flex flex-col gap-2 max-h-72 overflow-y-auto">
      <div :for={fila <- Enum.filter(@resultado, &(&1.resultado == :error))} class="border border-red-200 bg-red-50 rounded-lg px-2.5 py-1.5">
        <div class="font-semibold text-red-800 mb-1">Fila {fila.fila}</div>
        <div :for={err <- fila.errores} class="text-red-700">
          <span :if={err.etiqueta} class="font-semibold">{err.etiqueta}</span>
          <span :if={err.valor not in [nil, ""]}> ("{err.valor}")</span>
          : {err.mensaje}
          <div class="text-red-500">{err.sugerencia}</div>
        </div>
      </div>
    </div>
    """
  end

  # Las 4 piezas de abajo (celda_encabezado/celda_filtro/celda_body/
  # celda_resumen_col) son el dispatch por tipo de columna del Get View
  # unificado (ver construir_columnas_render/3) — una por cada fila de la
  # tabla (título, filtro, dato, resumen), SIEMPRE en el mismo orden
  # (@columnas_render), para que las 4 sigan alineadas verticalmente sin
  # importar qué tan mezclados queden campos de control y de negocio.
  # Reusan el markup exacto que ya tenía cada columna cuando la secuencia
  # era fija — esto es reordenar código, no una funcionalidad nueva.
  attr :col, :map, required: true

  defp celda_encabezado(%{col: %{tipo_columna: :negocio}} = assigns) do
    ~H"""
    <th data-col={@col.clave} class={[
      "px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide",
      alineacion_columna(@col.columna)
    ]}>
      <span class="inline-flex items-center gap-1">
        {@col.columna.schema_context_properties["etiqueta"]}
        <%= if @col.columna.schema_context_properties["tipo"] == "referencia" do %>
          <span class="material-symbols-outlined text-blue-500" style="font-size: 13px" title={"Relación con #{@col.columna.schema_context_properties["catalogo"]}"}>link</span>
        <% end %>
      </span>
    </th>
    """
  end

  defp celda_encabezado(assigns) do
    ~H"""
    <th data-col={@col.clave} class="px-2 py-3 sm:px-4 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide whitespace-nowrap">{@col.etiqueta}</th>
    """
  end

  attr :col, :map, required: true
  attr :filtros, :map, required: true

  defp celda_filtro(%{col: %{tipo_columna: :negocio}} = assigns) do
    bloqueado? = assigns.col.columna.schema_context_properties["filtro_default_bloqueado"] == true
    assigns = assign(assigns, :bloqueado?, bloqueado?)

    ~H"""
    <th data-col={@col.clave} class="px-2 py-1.5 sm:px-4 align-top">
      <.fila_filtro_columna columna={@col.columna} valores={@filtros} bloqueado?={@bloqueado?} />
    </th>
    """
  end

  defp celda_filtro(assigns) do
    ~H"""
    <th data-col={@col.clave} class="px-2 py-1.5 sm:px-4"></th>
    """
  end

  attr :col, :map, required: true
  attr :fila, :map, required: true

  defp celda_body(%{col: %{tipo_columna: :negocio}} = assigns) do
    valor = Map.get(assigns.fila, String.to_existing_atom(assigns.col.columna.schema_context_field))
    assigns = assign(assigns, :valor, valor)

    ~H"""
    <td data-col={@col.clave} class={[
      "px-2 py-2 text-[11px] sm:px-4 sm:py-1.5 sm:text-[10px]",
      alineacion_columna(@col.columna),
      clase_valor_celda(@valor, @col.columna.schema_context_properties)
    ]}>
      {formatear_celda(@valor, @col.columna.schema_context_properties)}
    </td>
    """
  end

  defp celda_body(%{col: %{tipo_columna: :id}} = assigns) do
    ~H"""
    <td data-col="id" class="px-2 py-2 text-[11px] sm:px-4 sm:py-1.5 sm:text-[10px] text-gray-700">{@fila.id}</td>
    """
  end

  defp celda_body(%{col: %{tipo_columna: :estado}} = assigns) do
    ~H"""
    <td data-col="estado" class="px-2 py-2 text-[11px] sm:px-4 sm:py-1.5 sm:text-[10px] text-gray-700">{Map.get(@fila, :estado_nombre)}</td>
    """
  end

  defp celda_body(%{col: %{tipo_columna: :trn}} = assigns) do
    ~H"""
    <td data-col="trn" class="px-2 py-2 text-[11px] sm:px-4 sm:py-1.5 sm:text-[10px] text-gray-700 font-mono" title={Map.get(@fila, :ulid)}>{Map.get(@fila, :trn)}</td>
    """
  end

  defp celda_body(%{col: %{tipo_columna: :empresa}} = assigns) do
    ~H"""
    <td data-col="empresa" class="px-2 py-2 text-[11px] sm:px-4 sm:py-1.5 sm:text-[10px] text-gray-700">{Map.get(@fila, :empresa_nombre)}</td>
    """
  end

  defp celda_body(%{col: %{tipo_columna: :branch}} = assigns) do
    ~H"""
    <td data-col="branch" class="px-2 py-2 text-[11px] sm:px-4 sm:py-1.5 sm:text-[10px] text-gray-700">{Map.get(@fila, :branch_nombre)}</td>
    """
  end

  defp celda_body(%{col: %{tipo_columna: :inventory_location}} = assigns) do
    ~H"""
    <td data-col="inventory_location" class="px-2 py-2 text-[11px] sm:px-4 sm:py-1.5 sm:text-[10px] text-gray-700">{Map.get(@fila, :inventory_nombre)}</td>
    """
  end

  defp celda_body(%{col: %{tipo_columna: :sales_unit}} = assigns) do
    ~H"""
    <td data-col="sales_unit" class="px-2 py-2 text-[11px] sm:px-4 sm:py-1.5 sm:text-[10px] text-gray-700">{Map.get(@fila, :sales_unit_nombre)}</td>
    """
  end

  defp celda_body(%{col: %{tipo_columna: :creado_por}} = assigns) do
    ~H"""
    <td data-col="creado_por" class="px-2 py-2 text-[11px] sm:px-4 sm:py-1.5 sm:text-[10px] text-gray-700">{Map.get(@fila, :creado_por)}</td>
    """
  end

  attr :col, :map, required: true
  attr :agregaciones, :map, required: true
  attr :valores, :map, required: true
  attr :minmax_valores, :map, required: true
  attr :totales_generales, :map, required: true
  attr :filas, :list, required: true

  defp celda_resumen_col(%{col: %{tipo_columna: :negocio}} = assigns) do
    ~H"""
    <.celda_resumen columna={@col.columna} agregaciones={@agregaciones} valores={@valores} minmax_valores={@minmax_valores} totales_generales={@totales_generales} filas={@filas} />
    """
  end

  # "Resumen" viajaba pegado a la celda de ID en la versión vieja (que
  # siempre iba primera) — se mantiene el mismo criterio: solo aparece si
  # la columna ID está visible, sea cual sea su posición ahora.
  defp celda_resumen_col(%{col: %{tipo_columna: :id}} = assigns) do
    ~H"""
    <td data-col="id" class="px-4 py-2 text-[9px] font-bold uppercase tracking-wide text-gray-400 whitespace-nowrap">Resumen</td>
    """
  end

  defp celda_resumen_col(assigns) do
    ~H"""
    <td data-col={@col.clave}></td>
    """
  end

  # Columnas numéricas alineadas a la derecha (más fácil comparar montos de
  # un vistazo) — el resto se queda a la izquierda como texto normal.
  defp alineacion_columna(%{schema_context_properties: %{"tipo" => tipo}})
       when tipo in ["integer", "decimal"],
       do: "text-right"

  defp alineacion_columna(_columna), do: "text-left"

  # En celular la columna de plata (integer/decimal) se resalta — es el
  # número que más se escanea de un vistazo en una tabla angosta. En
  # desktop queda como cualquier otra celda (sm:font-normal sm:text-gray-700
  # pisa el resalte), sin cambiar nada de lo que ya se veía ahí.
  defp clase_valor_celda(valor, %{"tipo" => tipo})
       when tipo in ["integer", "decimal"] and (is_number(valor) or is_struct(valor, Decimal)),
       do: "font-semibold text-gray-900 sm:font-normal sm:text-gray-700"

  defp clase_valor_celda(valor, _props) when is_map(valor) and not is_struct(valor), do: "text-blue-700 font-medium"
  defp clase_valor_celda(_valor, _props), do: "text-gray-700"

  # Identificador de columna para el selector de campos (data-col en
  # <th>/<td>, ver panel_campos/1 y el hook SelectorCampos en app.js).
  # Una consulta con JOIN puede repetir el mismo schema_context_field en
  # más de un catálogo (ej. "nombre" en dos tablas distintas) — ahí hace
  # falta la clave namespaced (:clave, ver columna_desde_campo_consulta/1)
  # para no confundir/ocultar la columna equivocada; un catálogo normal no
  # tiene :clave y usa el campo crudo, que ya es único. Siempre string
  # (nunca átomo) — a propósito: los eventos de formulario (ver
  # "cambiar_agregacion"/@agregaciones en celdas_resumen/1) llegan del
  # cliente como string, y `Map.has_key?/2`/`@agregaciones[clave]` no
  # matchea un átomo contra un string aunque el texto sea idéntico. Sin
  # el to_string/1 acá, la barra de Resumen quedaba muda en cualquier
  # consulta con JOIN (donde :clave es un átomo) — funcionaba solo en un
  # catálogo normal, donde el campo crudo ya era un string.
  defp col_key(columna), do: columna |> Map.get(:clave) |> Kernel.||(columna.schema_context_field) |> to_string()

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

  # Get View unificado (CatalogoLive) — @columnas_render ya viene en el
  # orden final (control + negocio mezclados, ver construir_columnas_render/3),
  # así que el popover de "Campos" lista todo en el mismo orden que las
  # columnas reales de la tabla.
  defp campos_selector_render(columnas_render) do
    Enum.map(columnas_render, &%{clave: &1.clave, etiqueta: &1.etiqueta})
  end

  # "Total 25" (Get View → Filtros → "Total 25", bc_motor_live.ex) — a
  # diferencia de "Totalizado" (recalcular_totales_generales/1, una query
  # de SUM sobre TODAS las filas que matchean), esto suma directo sobre
  # @filas (las ~25 que ya están cargadas para la página actual), sin
  # pegarle a la base — barato porque nunca son más que @por_pagina filas.
  defp total_columna_pagina(filas, columna) do
    filas
    |> Enum.map(&valor_fila(&1, columna))
    |> Enum.reduce(nil, &sumar_valor/2)
  end

  # Misma resolución de clave que usan las filas normales de la tabla —
  # `columna.clave` (namespaced, solo lo tienen las columnas de una
  # Consulta con JOIN, ver columna_desde_campo_consulta/1) si existe, si
  # no el schema_context_field crudo de un catálogo normal.
  defp valor_fila(fila, columna) do
    case Map.get(columna, :clave) do
      nil -> Map.get(fila, String.to_existing_atom(columna.schema_context_field))
      clave -> Map.get(fila, clave)
    end
  end

  defp sumar_valor(nil, acc), do: acc
  defp sumar_valor(%Decimal{} = valor, nil), do: valor
  defp sumar_valor(%Decimal{} = valor, acc), do: Decimal.add(acc, valor)
  defp sumar_valor(valor, nil), do: valor
  defp sumar_valor(valor, acc), do: valor + acc

  # `props` (schema_context_properties del campo) trae la máscara elegida
  # en Get View → Filtros → "Máscara" (solo para tipo "decimal", ver
  # panel_filtros_resumen/1 en bc_motor_live.ex): "mascara_separador" —
  # "," (default, formato 1,234.56) o "." (formato 1.234,56) — y
  # "mascara_simbolo" — "" (default) o "$" antepuesto. Un campo sin esas
  # claves (integer, o decimal nunca reconfigurado) cae en el default de
  # siempre, sin romper nada de lo que ya había.
  defp formatear_agregacion(nil, _props), do: "—"
  defp formatear_agregacion(%Decimal{} = valor, props), do: valor |> Decimal.to_float() |> formatear_agregacion(props)
  defp formatear_agregacion(valor, props) when is_integer(valor), do: aplicar_simbolo(separar_miles(valor, props), props)

  defp formatear_agregacion(valor, props) when is_float(valor) do
    separador_decimal = if Map.get(props, "mascara_separador", ",") == ",", do: ".", else: ","
    [entero, decimales] = valor |> :erlang.float_to_binary(decimals: 2) |> String.split(".")
    (separar_miles(String.to_integer(entero), props) <> separador_decimal <> decimales) |> aplicar_simbolo(props)
  end

  # Mín./Máx./Conteo de un campo NO numérico (string/boolean/date/enum,
  # desde que "Filtros" dejó de limitarse a integer/decimal) — Postgres
  # soporta MIN/MAX/COUNT sobre esos tipos igual, así que el valor que
  # llega acá puede ser cualquier cosa comparable. Sin mask que aplicar
  # (eso es puramente numérico), to_string/1 alcanza — Date/DateTime ya
  # implementan String.Chars con un formato legible de por sí.
  defp formatear_agregacion(valor, _props), do: to_string(valor)

  defp separar_miles(numero, props) when numero < 0, do: "-" <> separar_miles(-numero, props)

  defp separar_miles(numero, props) do
    separador = Map.get(props, "mascara_separador", ",")

    numero
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1#{separador}")
    |> String.reverse()
  end

  defp aplicar_simbolo(texto, props) do
    case Map.get(props, "mascara_simbolo", "") do
      "$" -> "$" <> texto
      _ -> texto
    end
  end

  # `props` (schema_context_properties de la columna) opcional — un
  # integer/decimal con "mascara_separador"/"mascara_simbolo" configurados
  # (ver panel de Máscara en celdas_resumen/1) se formatea con la MISMA
  # función que ya usa el Resumen (formatear_agregacion/2), así una
  # columna de plata se lee igual fila por fila que en su total.
  # Un campo tipo "referencia" con campos de acompañamiento configurados
  # llega acá como objeto anidado (%{id: 1, razon_social: "..."}), no como
  # escalar — se muestra el resumen legible (sin el id), no el mapa crudo.
  # `when not is_struct(mapa)` es necesario: un valor tipo Decimal/Date/
  # DateTime también hace match contra `%{}` (son structs = mapas), y sin
  # excluirlos acá se les destripaban los campos internos en vez de
  # mostrarse como el escalar que son.
  defp formatear_celda(%{} = mapa, _props) when not is_struct(mapa) do
    mapa
    |> Map.delete(:id)
    |> Map.values()
    |> Enum.map_join(" · ", &(if is_nil(&1), do: "", else: to_string(&1)))
  end

  defp formatear_celda(valor, %{"tipo" => tipo} = props)
       when tipo in ["integer", "decimal"] and (is_number(valor) or is_struct(valor, Decimal)) do
    formatear_agregacion(valor, props)
  end

  # "fecha_registro" (campo de sistema, ver MetaCatalogoGenerico) es un
  # %DateTime{} crudo — sin esto se veía en ISO 8601 ("2026-08-06T22:03:07Z"),
  # técnicamente correcto pero difícil de leer de un vistazo.
  defp formatear_celda(%DateTime{} = valor, _props), do: Calendar.strftime(valor, "%d/%m/%Y %H:%M")

  defp formatear_celda(valor, _props), do: valor

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
        class="hidden fixed inset-x-4 top-24 sm:absolute sm:inset-x-auto sm:right-0 sm:top-full sm:mt-2 w-auto sm:w-72 max-h-[70vh] bg-white rounded-xl shadow-xl border border-gray-200 z-50 flex flex-col"
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

  # "Resumen": una celda de pie de tabla POR CADA columna, alineada justo
  # debajo de su propia columna (mismo <td data-col=...> que usan las
  # filas normales, así que el hook SelectorCampos de "Campos" la oculta/
  # reordena junto con el resto sin código nuevo) — a propósito NO es una
  # barra aparte con tarjetitas: eso obligaba a leer una etiqueta para
  # saber a qué columna correspondía cada número. Alineado bajo la
  # columna, la respuesta es obvia de un vistazo, como el pie de una
  # hoja de cálculo. Solo integer/decimal muestran el selector — el
  # resto de las columnas quedan con la celda vacía, para no romper la
  # alineación con el header/las filas.
  #
  # A diferencia de "Campos" (100% cliente), esto SÍ va al servidor
  # (handle_event "cambiar_agregacion"): el valor tiene que salir de
  # TODAS las filas que matchean filtros/búsqueda, no solo las ~25 de la
  # página actual visible en el DOM.
  attr :columnas, :list, required: true
  attr :agregaciones, :map, required: true
  attr :valores, :map, required: true
  attr :minmax_valores, :map, required: true
  attr :totales_generales, :map, required: true
  attr :filas, :list, required: true
  attr :es_consulta?, :boolean, default: false

  defp celdas_resumen(assigns) do
    ~H"""
    <.celda_resumen :for={columna <- @columnas} columna={columna} agregaciones={@agregaciones} valores={@valores} minmax_valores={@minmax_valores} totales_generales={@totales_generales} filas={@filas} />
    """
  end

  # Extraído de celdas_resumen/1 de arriba — el cuerpo por columna, para
  # poder reusarlo desde celda_resumen_col/1 (Get View unificado de
  # CatalogoLive) sin duplicar todo este bloque. celdas_resumen/1 lo sigue
  # llamando en loop tal cual, así que la tabla de Consultas (que la usa
  # directo) no cambió en nada.
  attr :columna, :map, required: true
  attr :agregaciones, :map, required: true
  attr :valores, :map, required: true
  attr :minmax_valores, :map, required: true
  attr :totales_generales, :map, required: true
  attr :filas, :list, required: true

  defp celda_resumen(assigns) do
    clave = col_key(assigns.columna)
    props = assigns.columna.schema_context_properties
    numerico? = props["tipo"] in ["integer", "decimal"]
    agregable? = props["tipo"] != "referencia"

    assigns =
      assigns
      |> assign(:clave, clave)
      |> assign(:props, props)
      |> assign(:activo?, Map.has_key?(assigns.agregaciones, clave))
      |> assign(:numerico?, numerico?)
      |> assign(:agregable?, agregable?)
      |> assign(:agregacion_activa?, agregable? and props["agregacion_activa"] == true)
      |> assign(:minmax_recomendado?, numerico? and props["minmax_recomendado"] == true)
      |> assign(:total_pagina_activo?, numerico? and props["total_pagina_activo"] == true)
      |> assign(:total_general_activo?, numerico? and props["total_general_activo"] == true)

    ~H"""
    <td data-col={@clave} class={["px-4 py-2 align-top", alineacion_columna(@columna)]}>
      <%= if @agregable? do %>
        <div class={["flex items-center gap-1.5 flex-wrap", if(alineacion_columna(@columna) == "text-right", do: "flex-row-reverse", else: "")]}>
          <%= if @agregacion_activa? do %>
            <form phx-change="cambiar_agregacion">
              <input type="hidden" name="campo" value={@clave} />
              <select
                name="funcion"
                class="text-[10px] font-semibold text-purple-700 bg-transparent border-0 p-0 pr-4 focus:outline-none focus:ring-0 cursor-pointer"
              >
                <option value="" selected={!@activo?}>—</option>
                <option :if={@numerico?} value="suma" selected={@agregaciones[@clave] == "suma"}>Suma</option>
                <option :if={@numerico?} value="promedio" selected={@agregaciones[@clave] == "promedio"}>Promedio</option>
                <option value="conteo" selected={@agregaciones[@clave] == "conteo"}>Conteo</option>
              </select>
            </form>
            <span :if={@activo?} class="text-sm font-bold text-gray-900 tabular-nums whitespace-nowrap">
              {formatear_agregacion(@valores[@clave], @props)}
            </span>
          <% end %>

          <% {minimo, maximo} = @minmax_valores[@clave] || {nil, nil} %>
          <span :if={@minmax_recomendado?} class="text-[11px] font-bold text-gray-700 tabular-nums whitespace-nowrap">
            Mín. {formatear_agregacion(minimo, @props)} / Máx. {formatear_agregacion(maximo, @props)}
          </span>

          <span :if={@total_pagina_activo?} class="text-[11px] font-bold text-gray-700 tabular-nums whitespace-nowrap">
            Total 25: {formatear_agregacion(total_columna_pagina(@filas, @columna), @props)}
          </span>

          <span :if={@total_general_activo?} class="text-[11px] font-bold text-gray-700 tabular-nums whitespace-nowrap">
            Totalizado: {formatear_agregacion(@totales_generales[@clave], @props)}
          </span>
        </div>
      <% end %>
    </td>
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
    <div class="fixed inset-x-4 top-24 sm:absolute sm:inset-x-auto sm:right-0 sm:top-full sm:mt-2 w-auto sm:w-80 max-h-[70vh] bg-white rounded-xl shadow-xl border border-gray-200 z-50 flex flex-col">
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

      <div class="overflow-y-auto px-4 py-3 flex flex-col gap-3">
        <%= if @filtros_activos == [] do %>
          <p class="text-xs text-gray-400 text-center py-4">
            Sin filtros agregados — usa "Agregar filtro" para elegir un campo.
          </p>
        <% end %>
        <%= for campo <- @filtros_activos, columna = Enum.find(@columnas, &(&1.schema_context_field == campo)), columna do %>
          <% bloqueado? = columna.schema_context_properties["filtro_default_bloqueado"] == true %>
          <div class="flex items-start gap-1">
            <div class="flex-1">
              <.filtro_columna columna={columna} valores={@filtros} bloqueado?={bloqueado?} />
            </div>
            <div
              :if={bloqueado?}
              class="mt-5 w-5 h-5 flex-shrink-0 flex items-center justify-center text-gray-300"
              title="Este filtro está bloqueado — no se puede cambiar ni quitar"
            >
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <rect x="3" y="11" width="18" height="11" rx="2" ry="2" /><path d="M7 11V7a5 5 0 0 1 10 0v4" />
              </svg>
            </div>
            <button
              :if={!bloqueado?}
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
      </div>

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

  # Opciones del <select> de un filtro "enum"/"referencia" — usado tanto por
  # filtro_columna/1 (popover) como por fila_filtro_columna/1 (fila fija en
  # el thead), para que las dos UIs filtren el mismo campo con la misma
  # semántica (coincidencia exacta, no ILIKE).
  defp opciones_para_columna(%{schema_context_properties: %{"tipo" => "enum"} = props}),
    do: CampoInputComponents.opciones_enum(props["valores"])

  defp opciones_para_columna(%{schema_context_properties: %{"tipo" => "referencia"} = props}),
    do: CatalogoGenerico.opciones_referencia(props)

  # Etiqueta legible del valor actualmente elegido (para la rama
  # "bloqueado" de un filtro enum/referencia) — sin esto se mostraría el
  # código del enum o el id numérico crudo en vez de algo legible.
  defp etiqueta_seleccionada(opciones, valor) do
    case Enum.find(opciones, fn {v, _etiqueta} -> to_string(v) == to_string(valor) end) do
      {_v, etiqueta} -> etiqueta
      nil -> valor
    end
  end

  # Un widget de filtro distinto según el tipo de la columna (guardado en
  # meta_schema_detail) — así un catálogo nuevo sale con filtros
  # funcionando sin escribir nada a mano por catálogo. Los nombres de los
  # inputs (filtros[campo] / filtros[campo_desde] / filtros[campo_hasta])
  # tienen que calzar con lo que lee construir_filtros_ecto/2.
  #
  # `bloqueado?` (bc_motor_live.ex, "Bloqueado" en panel_filtros_resumen/1):
  # el usuario final ve el valor pero no lo puede tocar — en vez del
  # control editable normal, dibuja el valor como texto fijo + un
  # `<input type="hidden">` con el mismo `name` para que el submit del
  # form ("filtrar") lo siga mandando igual (un input con `disabled` NO se
  # manda en absoluto, por eso hidden en vez de eso).
  #
  # `form="form-filtros"`: este popover ya no es un <form> en sí (ver
  # panel_filtros/1) — el <form phx-change="filtrar"> real vive SIEMPRE
  # montado más arriba en el render (id="form-filtros"), aunque el popover
  # esté cerrado, para que la fila fija del thead (fila_filtro_columna/1)
  # tenga algo a que asociarse por `form=""` incluso sin abrir "Filtros".
  # Los inputs de acá se asocian al mismo form por el mismo mecanismo.
  attr :columna, :map, required: true
  attr :valores, :map, required: true
  attr :bloqueado?, :boolean, default: false

  defp filtro_columna(%{columna: %{schema_context_properties: %{"tipo" => "boolean"}}} = assigns) do
    campo = assigns.columna.schema_context_field
    assigns = assign(assigns, :campo, campo)

    ~H"""
    <div class="flex flex-col gap-1">
      <label class="text-[11px] font-semibold text-gray-500">{@columna.schema_context_properties["etiqueta"]}</label>
      <%= if @bloqueado? do %>
        <input type="hidden" form="form-filtros" name={"filtros[#{@campo}]"} value={@valores[@campo]} />
        <div class="w-full border border-gray-200 rounded bg-gray-50 text-gray-500 text-xs px-2 py-1.5">
          {texto_filtro_boolean(@valores[@campo])}
        </div>
      <% else %>
        <select form="form-filtros" name={"filtros[#{@campo}]"} class="w-full border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5">
          <option value="" selected={@valores[@campo] in [nil, ""]}>Todos</option>
          <option value="true" selected={@valores[@campo] == "true"}>Sí</option>
          <option value="false" selected={@valores[@campo] == "false"}>No</option>
        </select>
      <% end %>
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
      <%= if @bloqueado? do %>
        <input type="hidden" form="form-filtros" name={"filtros[#{@campo}_desde]"} value={@valores["#{@campo}_desde"]} />
        <input type="hidden" form="form-filtros" name={"filtros[#{@campo}_hasta]"} value={@valores["#{@campo}_hasta"]} />
        <div class="w-full border border-gray-200 rounded bg-gray-50 text-gray-500 text-xs px-2 py-1.5">
          {@valores["#{@campo}_desde"] || "…"} – {@valores["#{@campo}_hasta"] || "…"}
        </div>
      <% else %>
        <div class="flex items-center gap-1">
          <input
            type={@tipo_input}
            form="form-filtros"
            name={"filtros[#{@campo}_desde]"}
            value={@valores["#{@campo}_desde"]}
            placeholder="Desde"
            phx-debounce="400"
            class="w-0 flex-1 min-w-0 border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5"
          />
          <span class="text-gray-400 text-xs">–</span>
          <input
            type={@tipo_input}
            form="form-filtros"
            name={"filtros[#{@campo}_hasta]"}
            value={@valores["#{@campo}_hasta"]}
            placeholder="Hasta"
            phx-debounce="400"
            class="w-0 flex-1 min-w-0 border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5"
          />
        </div>
      <% end %>
    </div>
    """
  end

  defp filtro_columna(%{columna: %{schema_context_properties: %{"tipo" => tipo}}} = assigns)
       when tipo in ["enum", "referencia"] do
    campo = assigns.columna.schema_context_field
    opciones = opciones_para_columna(assigns.columna)
    assigns = assigns |> assign(:campo, campo) |> assign(:opciones, opciones)

    ~H"""
    <div class="flex flex-col gap-1">
      <label class="text-[11px] font-semibold text-gray-500">{@columna.schema_context_properties["etiqueta"]}</label>
      <%= if @bloqueado? do %>
        <input type="hidden" form="form-filtros" name={"filtros[#{@campo}]"} value={@valores[@campo]} />
        <div class="w-full border border-gray-200 rounded bg-gray-50 text-gray-500 text-xs px-2 py-1.5">
          {etiqueta_seleccionada(@opciones, @valores[@campo])}
        </div>
      <% else %>
        <select form="form-filtros" name={"filtros[#{@campo}]"} class="w-full border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5">
          <option value="" selected={@valores[@campo] in [nil, ""]}>Todos</option>
          <option :for={{valor, etiqueta} <- @opciones} value={valor} selected={to_string(@valores[@campo]) == to_string(valor)}>
            {etiqueta}
          </option>
        </select>
      <% end %>
    </div>
    """
  end

  defp filtro_columna(assigns) do
    campo = assigns.columna.schema_context_field
    assigns = assign(assigns, :campo, campo)

    ~H"""
    <div class="flex flex-col gap-1">
      <label class="text-[11px] font-semibold text-gray-500">{@columna.schema_context_properties["etiqueta"]}</label>
      <%= if @bloqueado? do %>
        <input type="hidden" form="form-filtros" name={"filtros[#{@campo}]"} value={@valores[@campo]} />
        <div class="w-full border border-gray-200 rounded bg-gray-50 text-gray-500 text-xs px-2 py-1.5">
          {@valores[@campo]}
        </div>
      <% else %>
        <input
          type="text"
          form="form-filtros"
          name={"filtros[#{@campo}]"}
          value={@valores[@campo]}
          placeholder="Buscar..."
          phx-debounce="400"
          class="w-full border border-gray-300 rounded text-gray-900 text-xs px-2 py-1.5"
        />
      <% end %>
    </div>
    """
  end

  defp texto_filtro_boolean("true"), do: "Sí"
  defp texto_filtro_boolean("false"), do: "No"
  defp texto_filtro_boolean(_valor), do: "Todos"

  # Fila de filtros SIEMPRE visible, pegada al encabezado de columna (thead)
  # — misma idea que filtro_columna/1 (popover "Filtros") y mismo despacho
  # por tipo, pero compacta (sin <label>, el nombre de columna ya está en
  # el <th> de arriba) y pensada para vivir en una celda angosta.
  #
  # `form="form-filtros"` en cada control: estos inputs viven en el thead
  # de la tabla, fuera del <form phx-change="filtrar" id="form-filtros">
  # (montado siempre, ver el bloque justo antes de la barra de búsqueda en
  # render/1 — TIENE que estar siempre en el DOM, no solo cuando el
  # popover de Filtros está abierto, si no `form=""` no tiene a qué
  # asociarse). El atributo `form` los asocia igual estando afuera
  # (estándar HTML5, ver Form.elements/FormData), así un solo submit
  # ("filtrar") junta los valores de las dos UIs sin pisarse.
  attr :columna, :map, required: true
  attr :valores, :map, required: true
  attr :bloqueado?, :boolean, default: false

  defp fila_filtro_columna(%{columna: %{schema_context_properties: %{"tipo" => "boolean"}}} = assigns) do
    campo = assigns.columna.schema_context_field
    assigns = assign(assigns, :campo, campo)

    ~H"""
    <%= if @bloqueado? do %>
      <input type="hidden" form="form-filtros" name={"filtros[#{@campo}]"} value={@valores[@campo]} />
      <span class="block truncate text-[10px] text-gray-400" title={texto_filtro_boolean(@valores[@campo])}>
        {texto_filtro_boolean(@valores[@campo])}
      </span>
    <% else %>
      <select form="form-filtros" name={"filtros[#{@campo}]"} class="w-full border border-gray-300 rounded text-gray-900 text-[10px] px-1.5 py-1">
        <option value="" selected={@valores[@campo] in [nil, ""]}>Todos</option>
        <option value="true" selected={@valores[@campo] == "true"}>Sí</option>
        <option value="false" selected={@valores[@campo] == "false"}>No</option>
      </select>
    <% end %>
    """
  end

  defp fila_filtro_columna(%{columna: %{schema_context_properties: %{"tipo" => tipo}}} = assigns)
       when tipo in ["integer", "decimal", "date"] do
    campo = assigns.columna.schema_context_field
    tipo_input = if tipo == "date", do: "date", else: "number"
    assigns = assigns |> assign(:campo, campo) |> assign(:tipo_input, tipo_input)

    ~H"""
    <%= if @bloqueado? do %>
      <input type="hidden" form="form-filtros" name={"filtros[#{@campo}_desde]"} value={@valores["#{@campo}_desde"]} />
      <input type="hidden" form="form-filtros" name={"filtros[#{@campo}_hasta]"} value={@valores["#{@campo}_hasta"]} />
      <span class="block truncate text-[10px] text-gray-400">
        {@valores["#{@campo}_desde"] || "…"} – {@valores["#{@campo}_hasta"] || "…"}
      </span>
    <% else %>
      <div class="flex items-center gap-0.5">
        <input
          type={@tipo_input}
          form="form-filtros"
          name={"filtros[#{@campo}_desde]"}
          value={@valores["#{@campo}_desde"]}
          placeholder="Desde"
          phx-debounce="400"
          class="w-0 flex-1 min-w-0 border border-gray-300 rounded text-gray-900 text-[10px] px-1.5 py-1"
        />
        <input
          type={@tipo_input}
          form="form-filtros"
          name={"filtros[#{@campo}_hasta]"}
          value={@valores["#{@campo}_hasta"]}
          placeholder="Hasta"
          phx-debounce="400"
          class="w-0 flex-1 min-w-0 border border-gray-300 rounded text-gray-900 text-[10px] px-1.5 py-1"
        />
      </div>
    <% end %>
    """
  end

  defp fila_filtro_columna(%{columna: %{schema_context_properties: %{"tipo" => tipo}}} = assigns)
       when tipo in ["enum", "referencia"] do
    campo = assigns.columna.schema_context_field
    opciones = opciones_para_columna(assigns.columna)
    assigns = assigns |> assign(:campo, campo) |> assign(:opciones, opciones)

    ~H"""
    <%= if @bloqueado? do %>
      <input type="hidden" form="form-filtros" name={"filtros[#{@campo}]"} value={@valores[@campo]} />
      <span class="block truncate text-[10px] text-gray-400" title={etiqueta_seleccionada(@opciones, @valores[@campo])}>
        {etiqueta_seleccionada(@opciones, @valores[@campo])}
      </span>
    <% else %>
      <select form="form-filtros" name={"filtros[#{@campo}]"} class="w-full border border-gray-300 rounded text-gray-900 text-[10px] px-1.5 py-1">
        <option value="" selected={@valores[@campo] in [nil, ""]}>Todos</option>
        <option :for={{valor, etiqueta} <- @opciones} value={valor} selected={to_string(@valores[@campo]) == to_string(valor)}>
          {etiqueta}
        </option>
      </select>
    <% end %>
    """
  end

  defp fila_filtro_columna(assigns) do
    campo = assigns.columna.schema_context_field
    assigns = assign(assigns, :campo, campo)

    ~H"""
    <%= if @bloqueado? do %>
      <input type="hidden" form="form-filtros" name={"filtros[#{@campo}]"} value={@valores[@campo]} />
      <span class="block truncate text-[10px] text-gray-400" title={@valores[@campo]}>{@valores[@campo]}</span>
    <% else %>
      <input
        type="text"
        form="form-filtros"
        name={"filtros[#{@campo}]"}
        value={@valores[@campo]}
        placeholder="Buscar..."
        phx-debounce="400"
        class="w-full border border-gray-300 rounded text-gray-900 text-[10px] px-1.5 py-1"
      />
    <% end %>
    """
  end

  # Recorre @columnas armando un <th data-col={...}> por columna dentro de
  # la fila fija de filtros — mismo data-col que la fila de encabezado de
  # arriba, así SelectorCampos (assets/js/app.js) la oculta/reordena en
  # sync sola cuando el usuario toca "Campos", igual que ya hace con
  # celdas_resumen/1 en el <tfoot>. Se reusa tal cual en la tabla de
  # catálogo y en la de consulta.
  attr :columnas, :list, required: true
  attr :filtros, :map, required: true

  defp fila_filtros_columnas(assigns) do
    ~H"""
    <%= for columna <- @columnas do %>
      <% bloqueado? = columna.schema_context_properties["filtro_default_bloqueado"] == true %>
      <th data-col={col_key(columna)} class="px-2 py-1.5 sm:px-4 align-top">
        <.fila_filtro_columna columna={columna} valores={@filtros} bloqueado?={bloqueado?} />
      </th>
    <% end %>
    """
  end
end
