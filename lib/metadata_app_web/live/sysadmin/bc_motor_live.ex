defmodule MetadataAppWeb.Sysadmin.BcMotorLive do
  # Plan de UI del Motor de Estados, construido por fases (ver memoria del
  # proyecto): Fase 2 (Estados + panel de salud), Fase 3 (Transiciones),
  # Fase 4 (diagrama Mermaid) — las tres de solo lectura. Fase 5 (acá) suma
  # la primera escritura real: agregar/quitar Reglas sobre transiciones que
  # YA existen. Sigue sin haber wizard de creación completa (eso usa
  # MetaEstadosAdmin.crear_proceso_completo/1, Fase 1, atómico) ni edición
  # de Estados/Transiciones en sí — eso queda para después.
  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_bc", "editar"}}

  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerador, CatalogoGenerico}
  alias MetadataApp.FiltrosDefault
  alias MetadataApp.MetaEstadosAdmin
  alias MetadataApp.MetaPlantillas
  alias MetadataApp.MetaReglasCodigo
  alias MetadataApp.Permissions
  alias MetadataAppWeb.AdminNav
  alias MetadataAppWeb.Sysadmin.FieldDesignerComponents
  alias Phoenix.LiveView.JS

  import MetadataAppWeb.FiltrosDefaultComponents, only: [panel_filtros_default: 1]

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "tepache", label: "Tepache Exp/Imp", nav: "/sysadmin/tepache"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"},
    %{tipo: :pagina, id: "credenciales", label: "Credenciales", nav: "/sysadmin/credenciales"},
    %{tipo: :pagina, id: "acciones_externas", label: "Acciones externas", nav: "/sysadmin/acciones-externas"},
    %{tipo: :pagina, id: "jerarquia", label: "Jerarquía organizacional", nav: "/sysadmin/jerarquia"}
  ]


  # Mismo set curado que BcListLive (modales de carpeta) — el ícono del
  # header se edita con el mismo selector en ambas pantallas.
  @iconos_sugeridos ~w(
    inventory_2 inventory shopping_cart storefront store sell local_offer
    category label folder folder_open description receipt_long assignment
    checklist rule task list_alt table_chart grid_view apps widgets
    dashboard bar_chart pie_chart insights trending_up payments credit_card
    attach_money account_balance business apartment factory warehouse
    local_shipping directions_car build engineering handyman construction
    group person people badge admin_panel_settings support_agent
    notifications campaign mail chat event schedule calendar_month
    place map public language security lock key qr_code print
    archive star favorite flag settings tune
  )

  def mount(%{"nombre" => nombre}, _session, socket) do
    header = MetaSchemaContext.obtener_header_por_nombre(nombre)

    socket =
      socket
      |> assign(:current_page, "bc_list")
      |> assign(:menu_items, @menu)
      |> assign(:sidebar_open, false)
      |> assign(:campo_form, nil)
      |> assign(:eliminar_campo_form, nil)
      |> assign(:relacion_form, nil)
      |> assign(:dependencia_form, nil)
      |> assign(:formato_form, nil)
      |> assign(:estado_form, nil)
      |> assign(:transicion_form, nil)
      |> assign(:header, header)
      |> assign(:header_form, header_form_desde(header))
      |> assign(:iconos_sugeridos, @iconos_sugeridos)
      |> assign(:carpetas, MetaSchemaContext.listar_carpetas_existentes())
      |> assign(:catalogos_referenciables, MetaSchemaContext.listar_catalogos_referenciables())
      |> assign(:reglas_mensajes, %{"pre" => nil, "post" => nil})
      |> assign(:compilar_disponible, MetaReglasCodigo.compilar_disponible?())

    {:ok, cargar_motor(socket)}
  end

  defp header_form_desde(nil), do: nil

  defp header_form_desde(header) do
    {carpeta_padre, segmento} = dividir_nav(header.schema_context_nav)

    %{
      "etiqueta" => header.schema_context_label,
      "carpeta_padre" => carpeta_padre,
      "segmento" => segmento,
      "icono" => header.schema_context_icono || "",
      "visible" => header.schema_visible,
      "error" => nil
    }
  end

  # "Navegación" se corrige a raíz de un bug real: dejar la ruta entera como
  # texto libre llevó a que alguien tipeara "/alyconfig/canales" a mano
  # editando OTRO catálogo, pisando sin darse cuenta la ruta de uno que
  # recién se había creado ahí — construir_arbol/1 solo puede mostrar un
  # nodo por ruta, así que el segundo en cargarse "hacía desaparecer" al
  # primero. Separar en carpeta (select, solo rutas de carpeta que ya
  # existen) + segmento propio (texto, pero validado contra colisión antes
  # de guardar) hace ese error estructuralmente imposible en la carpeta, y
  # detectable antes de guardar en el segmento.
  defp dividir_nav(nav) do
    case nav |> String.trim_leading("/") |> String.split("/", trim: true) do
      [] -> {"", ""}
      [unico] -> {"", unico}
      varios -> {varios |> Enum.slice(0..-2//1) |> Enum.join("/"), List.last(varios)}
    end
  end

  defp componer_nav_header(carpeta_padre, segmento) do
    cond do
      segmento == "" -> ""
      carpeta_padre in [nil, ""] -> "/" <> segmento
      true -> "/" <> carpeta_padre <> "/" <> segmento
    end
  end

  # Permisivo a propósito (no fuerza minúsculas): rutas ya existentes como
  # "/catalogos/Clientes" usan mayúsculas y forzar el case acá las cambiaría
  # solo por tocar este formulario, rompiendo cualquier link/bookmark viejo
  # que dependa del case exacto. Lo que sí se quita son espacios y "/" —
  # que es justo lo que permitía meter una ruta de varios niveles en lo que
  # se pensaba como "solo el segmento final".
  defp sanitizar_segmento_header(valor) do
    (valor || "")
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9\-_]/, "")
    |> String.slice(0, 50)
  end

  defp colisiona_con_otro?(nav, header_id) do
    case MetaSchemaContext.obtener_header_por_nav(nav) do
      nil -> false
      %{id: ^header_id} -> false
      _otro -> true
    end
  end

  defp cargar_motor(%{assigns: %{header: nil}} = socket), do: socket

  defp cargar_motor(%{assigns: %{header: header}} = socket) do
    {:ok, completitud} = MetaEstadosAdmin.completitud(header.schema_context_name)
    {:ok, validacion} = MetaEstadosAdmin.validar_motor(header.schema_context_name)
    estados = MetaEstadosAdmin.listar_estados(header.id)
    transiciones = MetaEstadosAdmin.listar_transiciones(header.id)

    catalogos_detalle =
      header.id
      |> MetaSchemaContext.listar_catalogos_detalle()
      |> Enum.map(fn h ->
        %{id: h.id, nombre: h.schema_context_name, etiqueta: h.schema_context_label, campos: MetaSchemaContext.listar_detalles(h.schema_context_name)}
      end)

    # Catálogo Maestro-Detalle (R3): acá, no en completitud/1, es donde se
    # necesita el header del MAESTRO (nombre/etiqueta) para el aviso y el
    # link de "Ver <maestro>" — completitud/1 solo necesita saber si ES
    # detalle, no de cuál.
    maestro = header.schema_encabezado_id && MetaSchemaContext.obtener_header!(header.schema_encabezado_id)

    socket
    |> assign(:campos, MetaSchemaContext.listar_detalles(header.schema_context_name))
    |> assign(:catalogos_detalle, catalogos_detalle)
    |> assign(:es_detalle?, header.schema_encabezado_id != nil)
    |> assign(:maestro, maestro)
    |> assign(:estados, estados)
    |> assign(:estados_por_id, Map.new(estados, &{&1.id, &1}))
    |> assign(:transiciones, transiciones)
    |> assign(:permisos_detalle, MetaEstadosAdmin.listar_permisos_detalle(header.id))
    |> assign(:diagrama, diagrama_mermaid(estados, transiciones))
    |> assign(:completitud, completitud)
    |> assign(:validacion, validacion)
    |> assign(:reglas, %{"pre" => MetaReglasCodigo.obtener(header.id, "pre"), "post" => MetaReglasCodigo.obtener(header.id, "post")})
  end

  # "grupo" del selector de campos editables: "header" o el
  # schema_context_name de un catálogo detalle — mismo valor que la key
  # del tab (ver tabs_motor en modal_transicion/1).
  defp campos_del_grupo(assigns, "header"), do: assigns.campos

  defp campos_del_grupo(assigns, grupo) do
    case Enum.find(assigns.catalogos_detalle, &(&1.nombre == grupo)) do
      nil -> []
      cat -> cat.campos
    end
  end

  # Un renglón de un catálogo detalle corre la MISMA transición del maestro
  # (R3), pero verificar_permiso_transicion/3 (MetaStateEngine) resuelve el
  # "recurso" del permiso por el registro que de verdad se mueve — para un
  # renglón, eso es la tabla DETALLE, no el encabezado. Sin una fila de
  # permiso {recurso: <detalle>, accion} registrada, NADIE puede mover
  # renglones de esa tabla en esa transición, ni el administrador — mismo
  # motivo que ya justificaba el botón para el encabezado, extendido acá a
  # cada catálogo detalle (encontrado real con pty_crac_clientes: "Activo"
  # permitía borrar por MetaEstadosAdmin.permiso_detalle/2 pero la
  # transición seguía rechazando porque esta fila nunca existió para
  # 'pty_pty_crac_clientesdet').
  defp permisos_transicion(header, catalogos_detalle, accion) do
    recursos = [{header.schema_context_name, header.schema_context_label} | Enum.map(catalogos_detalle, &{&1.nombre, &1.etiqueta})]

    Enum.map(recursos, fn {recurso, etiqueta} ->
      %{recurso: recurso, etiqueta: etiqueta, existe: Permissions.permiso_existe?(recurso, accion)}
    end)
  end

  # Bug real encontrado 2026-07-21: el botón de colapsar/expandir sidebar
  # (en MenuLayout.sidebar/1) empuja "change_page" con %{"id" =>
  # "toggle_sidebar"} — sin este handler, LiveView no tenía ninguna
  # clausula que matcheara y la pantalla explotaba con solo tocar ese
  # botón. Las demás pantallas admin (ej. BcListLive) ya delegaban a
  # AdminNav.handle_nav/3, acá faltaba.
  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, socket.assigns.current_page)
  end

  # --- Encabezado: etiqueta/navegación/ícono ----------------------------------

  def handle_event("validar_header", %{"header" => params}, socket) do
    carpeta_padre = params["carpeta_padre"] || ""
    segmento = sanitizar_segmento_header(params["segmento"])
    nav = componer_nav_header(carpeta_padre, segmento)

    error =
      if segmento != "" and colisiona_con_otro?(nav, socket.assigns.header.id) do
        "Esa ruta ya la usa otro catálogo o carpeta — elegí otra."
      end

    form = %{
      "etiqueta" => params["etiqueta"],
      "carpeta_padre" => carpeta_padre,
      "segmento" => segmento,
      "icono" => normalizar_icono(params["icono"]),
      "visible" => params["visible"] == "true",
      "error" => error
    }

    {:noreply, assign(socket, :header_form, form)}
  end

  def handle_event("elegir_icono_header", %{"icono" => icono}, socket) do
    {:noreply, update(socket, :header_form, &Map.put(&1, "icono", icono))}
  end

  def handle_event("guardar_header", %{"header" => params}, socket) do
    etiqueta = String.trim(params["etiqueta"] || "")
    carpeta_padre = params["carpeta_padre"] || ""
    segmento = sanitizar_segmento_header(params["segmento"])
    nav = componer_nav_header(carpeta_padre, segmento)
    header = socket.assigns.header

    cond do
      etiqueta == "" ->
        {:noreply, update(socket, :header_form, &Map.put(&1, "error", "La etiqueta no puede quedar vacía."))}

      segmento == "" ->
        {:noreply, update(socket, :header_form, &Map.put(&1, "error", "La navegación no puede quedar vacía."))}

      colisiona_con_otro?(nav, header.id) ->
        {:noreply,
         update(socket, :header_form, &Map.put(&1, "error", "Esa ruta ya la usa otro catálogo o carpeta — elegí otra."))}

      true ->
        attrs = %{
          "schema_context_label" => etiqueta,
          "schema_context_nav" => nav,
          "schema_context_icono" => nil_si_vacio(normalizar_icono(params["icono"])),
          "schema_visible" => params["visible"] == "true"
        }

        case MetaSchemaContext.actualizar_header(header, attrs) do
          {:ok, header} ->
            {:noreply,
             socket
             |> assign(:header, header)
             |> assign(:header_form, header_form_desde(header))
             |> put_flash(:info, "Encabezado actualizado.")}

          {:error, changeset} ->
            {:noreply, update(socket, :header_form, &Map.put(&1, "error", resumen_errores(changeset)))}
        end
    end
  end

  # --- Campos: agregar -----------------------------------------------------

  def handle_event("abrir_form_campo", _params, socket) do
    {:noreply, assign(socket, :campo_form, FieldDesignerComponents.estado_inicial())}
  end

  def handle_event("cerrar_form_campo", _params, socket) do
    {:noreply, assign(socket, :campo_form, nil)}
  end

  # --- Asistente de campos (Diseñador Inteligente) ---------------------------
  # Ver FieldDesignerComponents — el "Paso 3" del mockup de referencia
  # (configuración de la capacidad activada) se muestra INLINE debajo de
  # cada checkbox tildado del "Paso 2" (capacidades), no como una pantalla
  # de navegación aparte — así que acá solo hay dos pasos reales: 1
  # (tarjetas de tipo) y 2 (nombre/etiqueta + capacidades + su config).

  def handle_event("asistente_elegir_tipo", %{"tipo" => tipo}, socket) do
    {:noreply, update(socket, :campo_form, &FieldDesignerComponents.elegir_tipo(&1, tipo))}
  end

  def handle_event("asistente_cambiar_tipo", _params, socket) do
    {:noreply, update(socket, :campo_form, &Map.merge(&1, %{"paso" => 1, "tipo" => nil}))}
  end

  def handle_event("asistente_aplicar_sugerencia", %{"capacidades" => capacidades, "config" => config}, socket) do
    {:noreply, update(socket, :campo_form, &FieldDesignerComponents.aplicar_sugerencia(&1, capacidades, config))}
  end

  # phx-change del formulario entero del asistente (nombre/etiqueta,
  # checkboxes de capacidad, y todos los sub-campos de configuración que
  # aparecen inline) — un solo evento, mismo criterio que
  # formato_cambiar/2, porque no hay filas repetidas que reordenar acá
  # (a diferencia de dependencia_cambiar/2).
  def handle_event("asistente_cambiar", params, socket) do
    {:noreply,
     update(socket, :campo_form, fn form ->
       FieldDesignerComponents.aplicar_cambios(form, params, socket.assigns.campos)
     end)}
  end

  def handle_event("asistente_dependencia_agregar", _params, socket) do
    {:noreply, update(socket, :campo_form, &Map.update!(&1, "dependencias", fn deps -> deps ++ [%{"campo_padre" => "", "campo_remoto" => "", "obligatorio" => true}] end))}
  end

  def handle_event("asistente_dependencia_quitar", %{"indice" => indice}, socket) do
    i = String.to_integer(indice)
    {:noreply, update(socket, :campo_form, &Map.update!(&1, "dependencias", fn deps -> List.delete_at(deps, i) end))}
  end

  def handle_event("asistente_lista_agregar", _params, socket) do
    {:noreply, update(socket, :campo_form, &Map.update!(&1, "valores_lista", fn v -> v ++ [""] end))}
  end

  def handle_event("asistente_lista_quitar", %{"indice" => indice}, socket) do
    i = String.to_integer(indice)
    {:noreply, update(socket, :campo_form, &Map.update!(&1, "valores_lista", fn v -> List.delete_at(v, i) end))}
  end

  def handle_event("asistente_formula_insertar", %{"campo" => campo}, socket) do
    {:noreply, update(socket, :campo_form, &Map.update!(&1, "formula", fn f -> (f || "") <> "{#{campo}}" end))}
  end

  def handle_event("guardar_campo_asistente", _params, socket) do
    header = socket.assigns.header
    form = socket.assigns.campo_form

    case FieldDesignerComponents.construir_propiedades(form, socket.assigns.campos, header.schema_context_name) do
      {:ok, nombre, propiedades} ->
        guardar_campo_y_generar(socket, header, nombre, propiedades)

      {:error, motivo} ->
        {:noreply, update(socket, :campo_form, &Map.put(&1, "error", motivo))}
    end
  end

  # --- Campos: eliminar (con impacto + confirmar por nombre) -----------------

  def handle_event("abrir_eliminar_campo", %{"campo" => campo}, socket) do
    catalogo = socket.assigns.header.schema_context_name

    case CatalogoGenerador.impacto_campo(catalogo, campo) do
      {:ok, %{filas_con_valor: n}} ->
        {:noreply, assign(socket, :eliminar_campo_form, %{campo: campo, filas_con_valor: n, confirmar_texto: ""})}

      _ ->
        {:noreply, put_flash(socket, :error, "No se pudo consultar el impacto de ese campo.")}
    end
  end

  def handle_event("cancelar_eliminar_campo", _params, socket) do
    {:noreply, assign(socket, :eliminar_campo_form, nil)}
  end

  def handle_event("escribir_confirmacion_campo", %{"value" => texto}, socket) do
    {:noreply, update(socket, :eliminar_campo_form, &Map.put(&1, :confirmar_texto, texto))}
  end

  def handle_event("confirmar_eliminar_campo", _params, socket) do
    %{campo: campo, confirmar_texto: confirmar_texto} = socket.assigns.eliminar_campo_form
    catalogo = socket.assigns.header.schema_context_name

    case CatalogoGenerador.eliminar_campo(catalogo, campo, confirmar_texto) do
      {:ok, _resultado} ->
        {:noreply,
         socket
         |> assign(:eliminar_campo_form, nil)
         |> put_flash(:info, "Campo \"#{campo}\" eliminado.")
         |> cargar_motor()}

      {:error, motivo} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar el campo: #{inspect(motivo)}")}
    end
  end

  # --- Relaciones: qué campos de OTRO catálogo (el referenciado) trae de
  # prestado un campo tipo "referencia" de este ------------------------------
  #
  # Modos válidos de "campo_visualizacion" (persistidos tal cual en
  # schema_context_properties, ver aplicar_campo_visualizacion/2 más
  # abajo): "sin_configurar" (default del motor, sin nada elegido acá
  # todavía), "descripcion" (un solo campo), "codigo_descripcion" (dos
  # campos, en el orden que se quiera), "plantilla" (texto libre con
  # variables) y "calculado" (fórmula — ver MetaPlantillas.Formula). El
  # modal (modal_relacion/1) los presenta como 3 tarjetas de radio
  # ("Un solo dato" / "Dos datos combinados" / "Personalizado") más un
  # "Avanzado" colapsado para "calculado" — nunca como un <select> con
  # estos 5 nombres técnicos.

  def handle_event("abrir_form_relacion", %{"campo" => campo}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
    props = detalle.schema_context_properties

    campos_destino =
      props["catalogo"]
      |> MetaSchemaContext.listar_detalles()
      |> Enum.filter(& &1.schema_context_properties["visible"])

    campos_propios = Enum.filter(socket.assigns.campos, & &1.schema_context_properties["visible"])

    {:noreply,
     assign(socket, :relacion_form, %{
       "campo" => campo,
       "catalogo_destino" => props["catalogo"],
       "catalogo_destino_label" => MetaSchemaContext.obtener_header_por_nombre(props["catalogo"]).schema_context_label,
       "campos_destino" => campos_destino,
       "seleccionados" => props["campos_acompanamiento"] || [],
       "campos_propios" => campos_propios,
       "seleccionados_propios" => props["campos_relacion"] || [],
       "campo_visualizacion" => props["campo_visualizacion"] || campo_visualizacion_por_defecto(campos_destino),
       "registro_muestra" => registro_muestra_de(props["catalogo"]),
       "error" => nil
     })}
  end

  def handle_event("cerrar_form_relacion", _params, socket) do
    {:noreply, assign(socket, :relacion_form, nil)}
  end

  # Solo actualiza el estado en memoria (nunca la base) — así la vista
  # previa de "Configuración de visualización" reacciona en vivo mientras
  # se arma la plantilla/fórmula, sin que cada tecla dispare un guardado
  # real. El guardado de verdad sigue siendo phx-submit="guardar_relacion".
  def handle_event("previsualizar_visualizacion", params, socket) do
    campo_visualizacion = Map.get(params, "campo_visualizacion", %{})
    {:noreply, update(socket, :relacion_form, &Map.put(&1, "campo_visualizacion", campo_visualizacion))}
  end

  # Botones "insertar campo" de la plantilla/fórmula — mismo criterio que
  # el constructor de fórmulas de campo_calculado (agregar_token_formula/2
  # en PlantillaConstructorLive): concatenar texto al final, sin depender
  # de la posición del cursor en el input.
  def handle_event("insertar_variable_visualizacion", %{"campo" => campo, "destino" => destino}, socket) do
    cv = socket.assigns.relacion_form["campo_visualizacion"]
    actual = Map.get(cv, destino) || ""
    cv_actualizado = Map.put(cv, destino, actual <> "{#{campo}}")
    {:noreply, update(socket, :relacion_form, &Map.put(&1, "campo_visualizacion", cv_actualizado))}
  end

  def handle_event("guardar_relacion", params, socket) do
    %{"campo" => campo} = socket.assigns.relacion_form
    campos_seleccionados = params |> Map.get("campos", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    campos_relacion = params |> Map.get("campos_relacion", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    campo_visualizacion = Map.get(params, "campo_visualizacion", %{})
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))

    props =
      detalle.schema_context_properties
      |> Map.put("campos_acompanamiento", campos_seleccionados)
      |> Map.put("campos_relacion", campos_relacion)
      |> aplicar_campo_visualizacion(campo_visualizacion)

    case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
      {:ok, _detalle} ->
        {:noreply,
         socket
         |> assign(:relacion_form, nil)
         |> put_flash(:info, "Relación de \"#{campo}\" actualizada.")
         |> cargar_motor()}

      {:error, changeset} ->
        {:noreply, update(socket, :relacion_form, &Map.put(&1, "error", resumen_errores(changeset)))}
    end
  end

  # --- Dependencias ("combos en cascada") de un campo referencia -------------
  # Genérico: no hay ningún nombre de campo fijo acá — "campo_padre" tiene
  # que ser OTRO campo "referencia" de este mismo catálogo, "campo_remoto"
  # una columna del catálogo DESTINO de `campo` (mismo `campos_destino` que
  # ya arma abrir_form_relacion/1, no duplicado). Ver
  # MetaSchemaContext.resolver_filtros/3 (runtime) y validar_sin_ciclo/3
  # (acá, antes de guardar).
  def handle_event("abrir_form_dependencia", %{"campo" => campo}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
    props = detalle.schema_context_properties
    catalogo = socket.assigns.header.schema_context_name

    campos_destino =
      props["catalogo"]
      |> MetaSchemaContext.listar_detalles()
      |> Enum.filter(& &1.schema_context_properties["visible"])

    # Un campo que YA depende (directa o transitivamente) de `campo` no
    # puede ofrecerse como su padre — sería un ciclo inmediato. Filtro acá
    # para que el <select> ni siquiera lo muestre; validar_sin_ciclo/3
    # vuelve a chequear al guardar, por las dudas (ej. dos pestañas
    # abiertas a la vez).
    descendientes = catalogo |> MetaSchemaContext.descendientes(campo) |> MapSet.new()

    otros_referencia =
      socket.assigns.campos
      |> Enum.filter(&(&1.schema_context_properties["tipo"] == "referencia" and &1.schema_context_field != campo))
      |> Enum.reject(&MapSet.member?(descendientes, &1.schema_context_field))

    {:noreply,
     assign(socket, :dependencia_form, %{
       "campo" => campo,
       "catalogo" => catalogo,
       "catalogo_destino_label" => MetaSchemaContext.obtener_header_por_nombre(props["catalogo"]).schema_context_label,
       "campos_destino" => campos_destino,
       "otros_referencia" => otros_referencia,
       "dependencias" => props["dependencias"] || [],
       "descendientes" => MetaSchemaContext.descendientes(catalogo, campo),
       "error" => nil
     })}
  end

  def handle_event("cerrar_form_dependencia", _params, socket) do
    {:noreply, assign(socket, :dependencia_form, nil)}
  end

  def handle_event("dependencia_agregar", _params, socket) do
    nueva = %{"campo_padre" => "", "campo_remoto" => "", "obligatorio" => true}
    {:noreply, update(socket, :dependencia_form, &Map.update!(&1, "dependencias", fn deps -> deps ++ [nueva] end))}
  end

  def handle_event("dependencia_quitar", %{"indice" => indice}, socket) do
    i = String.to_integer(indice)
    {:noreply, update(socket, :dependencia_form, &Map.update!(&1, "dependencias", fn deps -> List.delete_at(deps, i) end))}
  end

  # phx-change del form entero — llega con TODAS las filas de una
  # (`dependencias[0][campo_padre]`, `dependencias[1][campo_padre]`, ...),
  # Plug ya las decodifica como mapa con llaves "0"/"1"/... (mismo truco
  # que renglones[IDX][...] en FichaLive) — se reordena acá una sola vez.
  def handle_event("dependencia_cambiar", %{"dependencias" => deps_params}, socket) do
    dependencias =
      deps_params
      |> Enum.sort_by(fn {indice, _valores} -> String.to_integer(indice) end)
      |> Enum.map(fn {_indice, valores} ->
        %{
          "campo_padre" => valores["campo_padre"],
          "campo_remoto" => valores["campo_remoto"],
          "obligatorio" => valores["obligatorio"] == "true"
        }
      end)

    {:noreply, update(socket, :dependencia_form, &Map.put(&1, "dependencias", dependencias))}
  end

  def handle_event("guardar_dependencia", _params, socket) do
    %{"campo" => campo, "catalogo" => catalogo, "dependencias" => dependencias} = socket.assigns.dependencia_form

    dependencias_validas =
      Enum.filter(dependencias, &(&1["campo_padre"] not in [nil, ""] and &1["campo_remoto"] not in [nil, ""]))

    case MetaSchemaContext.validar_sin_ciclo(catalogo, campo, dependencias_validas) do
      :ok ->
        detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
        props = Map.put(detalle.schema_context_properties, "dependencias", dependencias_validas)

        case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
          {:ok, _detalle} ->
            {:noreply,
             socket
             |> assign(:dependencia_form, nil)
             |> put_flash(:info, "Dependencia de \"#{campo}\" actualizada.")
             |> cargar_motor()}

          {:error, changeset} ->
            {:noreply, update(socket, :dependencia_form, &Map.put(&1, "error", resumen_errores(changeset)))}
        end

      {:error, motivo} ->
        {:noreply, update(socket, :dependencia_form, &Map.put(&1, "error", motivo))}
    end
  end

  # --- Formato de captura (máscaras de texto, número/moneda) -----------------
  # Config libre en schema_context_properties["formato_captura"], sin
  # regenerar el schema — mismo criterio que "dependencias" arriba (ver
  # MetaSchemaContext.validar_formato_captura/2). Un solo panel (no el
  # wizard de 4 pasos del mockup de referencia) con los campos que aplican
  # según el `tipo` real del campo: posicional para "string", numérico
  # para "integer"/"decimal".
  def handle_event("abrir_form_formato", %{"campo" => campo}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
    props = detalle.schema_context_properties
    tipo = props["tipo"]
    actual = props["formato_captura"] || %{}
    modo = actual["modo"] || modo_por_defecto(tipo)

    {:noreply,
     assign(socket, :formato_form, %{
       "campo" => campo,
       "tipo" => tipo,
       "habilitada" => actual["habilitada"] == true,
       "modo" => modo,
       "patron" => actual["patron"] || patron_por_defecto(modo) || "",
       "guardar_formato" => actual["guardar_formato"] != false,
       "decimales" => actual["decimales"] || 2,
       "separador_miles" => actual["separador_miles"] != false,
       "simbolo" => actual["simbolo"] || "$",
       "simbolo_posicion" => actual["simbolo_posicion"] || "prefijo",
       "permitir_negativos" => actual["permitir_negativos"] == true,
       "estricto" => actual["estricto"] != false,
       "permitir_incompleto" => actual["permitir_incompleto"] != false,
       "mensaje_invalido" => actual["mensaje_invalido"] || "",
       "error" => nil
     })}
  end

  def handle_event("cerrar_form_formato", _params, socket) do
    {:noreply, assign(socket, :formato_form, nil)}
  end

  # phx-change del panel entero — a diferencia de "dependencia_cambiar" no
  # hay filas repetidas que reordenar, así que se puede leer `params`
  # directo campo por campo.
  def handle_event("formato_cambiar", params, socket) do
    {:noreply,
     update(socket, :formato_form, fn form ->
       modo = params["modo"] || form["modo"]

       form
       |> Map.put("habilitada", params["habilitada"] == "true")
       |> Map.put("modo", modo)
       |> Map.put("patron", patron_por_defecto(modo) || Map.get(params, "patron", form["patron"]))
       |> Map.put("guardar_formato", params["guardar_formato"] != "false")
       |> Map.put("decimales", to_entero_seguro(params["decimales"], form["decimales"]))
       |> Map.put("separador_miles", params["separador_miles"] == "true")
       |> Map.put("simbolo", Map.get(params, "simbolo", form["simbolo"]))
       |> Map.put("simbolo_posicion", params["simbolo_posicion"] || form["simbolo_posicion"])
       |> Map.put("permitir_negativos", params["permitir_negativos"] == "true")
       |> Map.put("estricto", params["estricto"] == "true")
       |> Map.put("permitir_incompleto", params["permitir_incompleto"] == "true")
       |> Map.put("mensaje_invalido", Map.get(params, "mensaje_invalido", form["mensaje_invalido"]))
     end)}
  end

  def handle_event("guardar_formato", _params, socket) do
    form = socket.assigns.formato_form
    campo = form["campo"]

    case construir_formato_captura(form) do
      {:ok, formato} ->
        detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
        props = Map.put(detalle.schema_context_properties, "formato_captura", formato)

        case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
          {:ok, _detalle} ->
            {:noreply,
             socket
             |> assign(:formato_form, nil)
             |> put_flash(:info, "Formato de captura de \"#{campo}\" actualizado.")
             |> cargar_motor()}

          {:error, changeset} ->
            {:noreply, update(socket, :formato_form, &Map.put(&1, "error", resumen_errores(changeset)))}
        end

      {:error, motivo} ->
        {:noreply, update(socket, :formato_form, &Map.put(&1, "error", motivo))}
    end
  end

  # "En tabla" de un campo — si aparece como columna en la tabla del tab
  # Detalle de la Ficha 360° (catálogos con muchos campos quieren mostrar
  # solo un subconjunto ahí; el formulario de al lado siempre muestra
  # todos). Guardado inmediato, sin modal.
  def handle_event("cambiar_mostrar_en_tabla", %{"campo" => campo, "mostrar_en_tabla" => valor}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
    props = Map.put(detalle.schema_context_properties, "mostrar_en_tabla", valor == "true")

    case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
      {:ok, _detalle} -> {:noreply, cargar_motor(socket)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo actualizar \"#{campo}\".")}
    end
  end

  # Etiqueta de un campo ya existente (2026-08-04, a pedido explícito) —
  # mismo criterio inmediato que cambiar_mostrar_en_tabla de arriba: sin
  # modal, guarda directo al perder foco (evento "change"
  # nativo de un <input type="text">, no dispara por cada tecla). Antes
  # solo se podía definir al crear el campo — ver
  # MetaImportExport.sincronizar_etiquetas_campos/2 para la otra mitad
  # (que esto también se propague al publicar a un catálogo ya existente).
  def handle_event("cambiar_etiqueta_campo", %{"campo" => campo, "etiqueta" => etiqueta}, socket) do
    etiqueta = String.trim(etiqueta)
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))

    if etiqueta == "" do
      {:noreply, put_flash(socket, :error, "La etiqueta no puede quedar vacía.")}
    else
      props = Map.put(detalle.schema_context_properties, "etiqueta", etiqueta)

      case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
        {:ok, _detalle} -> {:noreply, cargar_motor(socket)}
        {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo actualizar la etiqueta de \"#{campo}\".")}
      end
    end
  end

  # "Obligatorio" de un campo ya existente (2026-08-05, a pedido explícito)
  # — inverso de "opcional" en schema_context_properties (se guarda con
  # ese nombre por compatibilidad: CatalogoGenerador/MetaCatalogoGenerico
  # ya lo leen así en cada regeneración, ver @campos_requeridos en
  # MetaCatalogoGenerico.__using__/1). A propósito SOLO nivel app
  # (validate_required vía el schema regenerado) — nunca ALTER COLUMN, la
  # columna física se queda nullable siempre. Por eso, a diferencia de
  # cambiar_etiqueta_campo/2, este SÍ necesita CatalogoGenerador.generar/1
  # después de guardar: es lo que recompila el schema con
  # @campos_requeridos actualizado (ver comentario en
  # CatalogoGenerador.generar/1 sobre por qué siempre regenera, no solo
  # cuando hay columnas nuevas).
  def handle_event("cambiar_obligatorio_campo", %{"campo" => campo, "obligatorio" => valor}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
    props = Map.put(detalle.schema_context_properties, "opcional", valor != "true")
    actualizar_campo_y_regenerar(socket, detalle, props, "la obligatoriedad")
  end

  # "Valor default forzoso" — si el campo es obligatorio Y llega vacío al
  # guardar, MetaCatalogoGenerico.changeset/2 lo rellena con este valor en
  # vez de rechazar el cambio (ver forzar_defaults/2 ahí). Es una regla
  # blanda a propósito: nunca bloquea el guardado, solo garantiza que no
  # quede vacío. Sin sentido para una referencia (no hay un valor
  # razonable para inventar una FK a ciegas — mismo criterio que
  # columna_migracion_agregar/3 en CatalogoGenerador), el input
  # correspondiente ni se muestra para ese tipo.
  def handle_event("cambiar_valor_default_campo", %{"campo" => campo, "valor_default" => valor}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
    valor = String.trim(valor)

    props =
      if valor == "" do
        Map.delete(detalle.schema_context_properties, "valor_default")
      else
        Map.put(detalle.schema_context_properties, "valor_default", valor)
      end

    actualizar_campo_y_regenerar(socket, detalle, props, "el valor default")
  end

  # Reordenar la tabla de Campos (drag-and-drop, hook ListaOrdenable) —
  # 2026-08-06, a pedido explícito: antes "orden" solo se fijaba una vez
  # al crear el campo (length(@campos) + 1), corregirlo después era
  # borrar y volver a crear. Puramente metadata (MetaSchemaContext.
  # reordenar_campos/2 no toca la columna física ni corre
  # CatalogoGenerador.generar/1) — @campos sale ordenado por "orden" ya
  # en la query de listar_detalles/1, así que cargar_motor/1 alcanza
  # para reflejar el nuevo orden, no hace falta nada más.
  def handle_event("mover_a", %{"id" => id, "index" => index}, socket) do
    orden_actual = Enum.map(socket.assigns.campos, & &1.schema_context_field)
    nuevo_orden = orden_actual |> List.delete(id) |> List.insert_at(index, id)

    :ok = MetaSchemaContext.reordenar_campos(socket.assigns.header.id, nuevo_orden)

    {:noreply, cargar_motor(socket)}
  end

  # --- Filtros: qué campos calculan un total en la fila de Resumen del -------
  # catálogo — sección aparte de la tabla de campos de arriba, "cantidad"
  # (el campo real, con su Nombre/Etiqueta/Tipo/Visible) no tiene nada que
  # ver con esto: acá solo se elige, de la lista de campos del catálogo,
  # cuáles participan del Resumen. Arranca sin "Mín. Máx." (se prende
  # aparte, en la tabla de abajo, y solo para numéricos — no tiene sentido
  # pedirlo acá antes de saber si el campo elegido siquiera calificaría).
  # Guardado inmediato, mismo criterio que cambiar_mostrar_en_tabla/2 arriba.
  def handle_event("agregar_filtro_resumen", %{"campo" => campo}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))

    props =
      detalle.schema_context_properties
      |> Map.put("agregacion_activa", true)
      |> Map.put("minmax_recomendado", false)

    case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
      {:ok, _detalle} -> {:noreply, cargar_motor(socket)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo agregar el filtro de \"#{campo}\".")}
    end
  end

  def handle_event("quitar_filtro_resumen", %{"campo" => campo}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))

    props =
      detalle.schema_context_properties
      |> Map.put("agregacion_activa", false)
      |> Map.put("minmax_recomendado", false)
      |> Map.put("total_pagina_activo", false)
      |> Map.put("total_general_activo", false)
      |> Map.delete("filtro_default_valor")
      |> Map.delete("filtro_default_desde")
      |> Map.delete("filtro_default_hasta")
      |> Map.delete("filtro_default_bloqueado")

    case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
      {:ok, _detalle} -> {:noreply, cargar_motor(socket)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo quitar el filtro de \"#{campo}\".")}
    end
  end

  # "Valor por default" de un filtro ya agregado (campos boolean/string/
  # enum, un solo valor) — CatalogoLive lo lee para pre-llenar Y aplicar
  # ese filtro apenas se abre la tabla (ver filtros_default_desde_columnas/1
  # ahí), no solo mostrar la fila vacía. "" borra el default (vuelve a
  # "Cualquiera"/sin acotar).
  def handle_event("cambiar_filtro_valor_default", %{"campo" => campo, "valor" => valor}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
    props = Map.put(detalle.schema_context_properties, "filtro_default_valor", valor)

    case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
      {:ok, _detalle} -> {:noreply, cargar_motor(socket)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo actualizar el valor por default de \"#{campo}\".")}
    end
  end

  # Mismo concepto que arriba pero para integer/decimal/date (rango
  # desde/hasta, dos inputs independientes) — "extremo" es "desde" o
  # "hasta".
  def handle_event("cambiar_filtro_rango_default", %{"campo" => campo, "extremo" => extremo, "valor" => valor}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
    clave = if extremo == "desde", do: "filtro_default_desde", else: "filtro_default_hasta"
    props = Map.put(detalle.schema_context_properties, clave, valor)

    case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
      {:ok, _detalle} -> {:noreply, cargar_motor(socket)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo actualizar el valor por default de \"#{campo}\".")}
    end
  end

  # "Bloqueado" — el usuario final ve este filtro ya puesto pero no puede
  # tocarlo ni quitarlo (ver panel_filtros/1 y filtro_columna/1 en
  # catalogo_live.ex, que lo dibujan como texto fijo + input oculto en vez
  # del control editable normal) — solo puede AGREGAR otros filtros
  # aparte. No afecta nada acá del lado del admin: "Quitar" de esta tabla
  # sigue funcionando igual, esto es una restricción para el usuario
  # final, no para quien configura el catálogo.
  def handle_event("cambiar_filtro_bloqueado", %{"campo" => campo, "bloqueado" => bloqueado}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
    props = Map.put(detalle.schema_context_properties, "filtro_default_bloqueado", bloqueado == "true")

    case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
      {:ok, _detalle} -> {:noreply, cargar_motor(socket)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo actualizar el bloqueo de \"#{campo}\".")}
    end
  end

  # "Todos por default" — a diferencia de los filtros de arriba (calculan
  # Suma/Promedio/Conteo sobre un CAMPO), esto es a nivel de todo el
  # catálogo: si está prendido, CatalogoLive trae todos los registros y
  # columnas apenas se abre la tabla, sin esperar que el usuario final
  # aplique un filtro/búsqueda primero (ver datos_solicitados?/1 en
  # catalogo_live.ex). Independiente de "Filtro de fecha" — apagar este no
  # toca el otro, se pueden combinar o usar por separado. El usuario final
  # igual puede seguir filtrando después con los filtros normales de la
  # tabla — esto solo cambia si arranca vacía o ya cargada.
  def handle_event("toggle_cargar_todos_por_default", _params, socket) do
    header = socket.assigns.header
    valor = !header.cargar_todos_por_default

    case MetaSchemaContext.actualizar_header(header, %{"cargar_todos_por_default" => valor}) do
      {:ok, header_actualizado} -> {:noreply, socket |> assign(:header, header_actualizado) |> cargar_motor()}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo actualizar \"Todos por default\".")}
    end
  end

  # Get View → columnas estructurales (ID/Estado/TRN) — mismo criterio
  # inmediato que toggle_cargar_todos_por_default/2 de arriba. Estado/TRN
  # ya se ocultaban solos cuando el catálogo no calificaba (sin motor de
  # estados / no transaccional, ver CatalogoLive.mount/3); esto agrega el
  # apagador de admin ENCIMA de esa condición, no en vez de ella.
  # Alcance de Datos (Fase 6, 2026-08-11; toggle relocado 2026-08-12 a
  # CatalogoPermisosLive/pestaña Permisos, ver ese módulo — "revuelve
  # mucho" tenerlo separado de la config por rol en otra pestaña).

  def handle_event("toggle_mostrar_id_en_tabla", _params, socket),
    do: toggle_columna_estructural(socket, :mostrar_id_en_tabla, "\"Mostrar ID\"")

  def handle_event("toggle_mostrar_estado_en_tabla", _params, socket),
    do: toggle_columna_estructural(socket, :mostrar_estado_en_tabla, "\"Mostrar Estado\"")

  def handle_event("toggle_mostrar_trn_en_tabla", _params, socket),
    do: toggle_columna_estructural(socket, :mostrar_trn_en_tabla, "\"Mostrar TRN\"")

  # Sub-filtro de fecha de "Filtros por default" — "primer_dia_anio"/
  # "ultimo_dia_anio"/"actual" (una sola fecha por calendario, precargada
  # con el valor obvio de cada modo — el usuario la puede cambiar
  # después) / "rango" (necesita desde Y hasta, dos calendarios, sin
  # precargar porque no hay un valor obvio para ninguno de los dos) o ""
  # para apagarlo — al cambiar de modo se limpian las fechas viejas para
  # no dejar pegado un valor de un modo distinto (ver
  # cambiar_filtro_fecha_valor/2 abajo).
  def handle_event("cambiar_filtro_fecha_modo", %{"modo" => modo}, socket) do
    header = socket.assigns.header
    valor_default = FiltrosDefault.valor_default_para_modo(modo)

    attrs = %{
      "filtro_default_fecha_modo" => if(modo == "", do: nil, else: modo),
      "filtro_default_fecha_valor" => valor_default,
      "filtro_default_fecha_valor_hasta" => nil
    }

    case MetaSchemaContext.actualizar_header(header, attrs) do
      {:ok, header_actualizado} -> {:noreply, socket |> assign(:header, header_actualizado) |> cargar_motor()}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo actualizar el filtro de fecha.")}
    end
  end

  # "campo" es "desde"/"hasta" (modo "rango", dos inputs) o siempre
  # "desde" para los modos de una sola fecha ("actual"/"primer_dia_anio"/
  # "ultimo_dia_anio"). Para estos dos últimos el <input> ya trae min/max
  # acotando al año en curso (ver FiltrosDefault.min_calendario_unico/1),
  # pero se re-valida acá server-side porque el min/max de un <input
  # type="date"> se puede saltear escribiendo el valor a mano.
  def handle_event("cambiar_filtro_fecha_valor", %{"campo" => campo, "valor" => valor}, socket) do
    header = socket.assigns.header
    clave = if campo == "desde", do: "filtro_default_fecha_valor", else: "filtro_default_fecha_valor_hasta"

    if FiltrosDefault.fecha_fuera_de_anio_actual?(header.filtro_default_fecha_modo, valor) do
      {:noreply,
       put_flash(socket, :error, "La fecha tiene que ser del año en curso (#{Date.utc_today().year}).")}
    else
      case MetaSchemaContext.actualizar_header(header, %{clave => valor}) do
        {:ok, header_actualizado} -> {:noreply, socket |> assign(:header, header_actualizado) |> cargar_motor()}
        {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo actualizar la fecha.")}
      end
    end
  end

  # "Mín. Máx." de un filtro ya agregado — extra Mín/Máx: si está
  # prendido, CatalogoLive lo muestra siempre junto al cálculo principal
  # en la fila de Resumen (celdas_resumen/1 ahí respeta este flag), no es
  # una elección del usuario final, es on/off.
  def handle_event("cambiar_minmax_recomendado", %{"campo" => campo, "recomendado" => recomendado}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
    props = Map.put(detalle.schema_context_properties, "minmax_recomendado", recomendado == "true")

    case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
      {:ok, _detalle} -> {:noreply, cargar_motor(socket)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo actualizar \"Mín. Máx.\" de \"#{campo}\".")}
    end
  end

  # "Total 25" — suma de SOLO los registros de la página actual (ver
  # total_columna_pagina/2 en catalogo_live.ex, calculado del lado del
  # cliente sobre @filas, sin query nueva). Solo tiene sentido para
  # integer/decimal — el botón ni se muestra para otros tipos (ver
  # panel_filtros_resumen/1 abajo).
  def handle_event("cambiar_total_pagina", %{"campo" => campo, "activo" => activo}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
    props = Map.put(detalle.schema_context_properties, "total_pagina_activo", activo == "true")

    case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
      {:ok, _detalle} -> {:noreply, cargar_motor(socket)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo actualizar \"Total 25\" de \"#{campo}\".")}
    end
  end

  # "Totalizado" — suma de TODOS los registros que matchean filtro/búsqueda,
  # no solo la página (ver recalcular_totales_generales/1 en
  # catalogo_live.ex, misma query de agregación que "Suma", solo que
  # siempre activa en vez de necesitar elegirla del selector).
  def handle_event("cambiar_total_general", %{"campo" => campo, "activo" => activo}, socket) do
    detalle = Enum.find(socket.assigns.campos, &(&1.schema_context_field == campo))
    props = Map.put(detalle.schema_context_properties, "total_general_activo", activo == "true")

    case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
      {:ok, _detalle} -> {:noreply, cargar_motor(socket)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo actualizar \"Totalizado\" de \"#{campo}\".")}
    end
  end

  # --- Get View: qué campos ve el usuario final en la tabla del catálogo ------

  def handle_event("guardar_get_view", params, socket) do
    visibles = params |> Map.get("visibles", []) |> List.wrap() |> MapSet.new()

    resultado =
      Enum.reduce_while(socket.assigns.campos, :ok, fn detalle, :ok ->
        props = Map.put(detalle.schema_context_properties, "visible", detalle.schema_context_field in visibles)

        case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
          {:ok, _detalle} -> {:cont, :ok}
          {:error, changeset} -> {:halt, {:error, detalle.schema_context_field, changeset}}
        end
      end)

    case resultado do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Get View actualizado.")
         |> cargar_motor()}

      {:error, campo, changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo actualizar \"#{campo}\": #{resumen_errores(changeset)}")}
    end
  end

  # --- Estados: agregar/editar/eliminar ----------------------------------------

  # El botón ya viene disabled en tabla_estados/1 mientras no haya Campos
  # (ver motor_stepper) — este chequeo es la versión que de verdad importa,
  # por si alguien manda el evento igual saltándose el disabled del cliente.
  def handle_event("abrir_form_estado", _params, socket) do
    if socket.assigns.completitud.tiene_campos do
      es_el_primero? = socket.assigns.estados == []

      {:noreply,
       assign(socket, :estado_form, %{
         "id" => nil,
         "nombre" => "",
         "orden" => to_string(length(socket.assigns.estados) + 1),
         "es_inicial" => es_el_primero?,
         "es_inicial_forzado" => es_el_primero?,
         "color" => "#7c3aed",
         "error" => nil
       })}
    else
      {:noreply, put_flash(socket, :error, "Agregá al menos un campo antes de agregar estados.")}
    end
  end

  def handle_event("abrir_editar_estado", %{"id" => id}, socket) do
    estado = Enum.find(socket.assigns.estados, &(&1.id == String.to_integer(id)))

    {:noreply,
     assign(socket, :estado_form, %{
       "id" => estado.id,
       "nombre" => estado.nombre,
       "orden" => to_string(estado.orden),
       "es_inicial" => estado.es_inicial,
       "es_inicial_forzado" => false,
       "color" => estado.color || "#7c3aed",
       "error" => nil
     })}
  end

  def handle_event("cerrar_form_estado", _params, socket) do
    {:noreply, assign(socket, :estado_form, nil)}
  end

  def handle_event("guardar_estado", params, socket) do
    nombre = String.trim(params["nombre"] || "")

    attrs = %{
      "meta_schema_header_id" => socket.assigns.header.id,
      "nombre" => nombre,
      "orden" => params["orden"],
      "es_inicial" => params["es_inicial"] == "true",
      "color" => nil_si_vacio(params["color"])
    }

    resultado =
      case params["registro_id"] do
        "" ->
          MetaEstadosAdmin.crear_estado(attrs)

        id ->
          estado = Enum.find(socket.assigns.estados, &(&1.id == String.to_integer(id)))
          MetaEstadosAdmin.actualizar_estado(estado, attrs)
      end

    case resultado do
      {:ok, _estado} ->
        {:noreply,
         socket
         |> assign(:estado_form, nil)
         |> put_flash(:info, "Estado \"#{nombre}\" guardado.")
         |> cargar_motor()}

      {:error, changeset} ->
        {:noreply, update(socket, :estado_form, &Map.put(&1, "error", resumen_errores(changeset)))}
    end
  end

  # El botón "Eliminar" ya viene oculto en la tabla si hay alguna
  # transición que referencia este estado (mismo criterio que ya usamos
  # para carpetas en BC List) — esta revalidación es la misma protección
  # de segunda línea, por si el árbol del cliente quedó desactualizado.
  def handle_event("eliminar_estado", %{"id" => id}, socket) do
    estado = Enum.find(socket.assigns.estados, &(&1.id == String.to_integer(id)))

    case MetaEstadosAdmin.eliminar_estado(estado) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Estado \"#{estado.nombre}\" eliminado.") |> cargar_motor()}

      {:error, :tiene_transiciones} ->
        {:noreply, put_flash(socket, :error, "Ese estado todavía lo usa una transición — quitá la transición primero.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar el estado.")}
    end
  end

  # --- Transiciones: agregar/editar/eliminar ------------------------------------

  # Mismo criterio que abrir_form_estado/3: el botón ya viene disabled
  # mientras no haya un estado inicial (o transición de alta) definido, este
  # chequeo es el que de verdad importa.
  def handle_event("abrir_form_transicion", _params, socket) do
    %{tiene_estados: tiene_estados, tiene_alta_o_inicial: tiene_alta_o_inicial} = socket.assigns.completitud

    if tiene_estados and tiene_alta_o_inicial do
      {:noreply,
       assign(socket, :transicion_form, %{
         "id" => nil,
         "accion" => "",
         "etiqueta" => "",
         "estado_origen_id" => "",
         "estado_destino_id" => "",
         "campos_editables" => [],
         "busqueda_campos" => %{},
         "error" => nil
       })}
    else
      {:noreply, put_flash(socket, :error, "Definí un estado inicial antes de agregar transiciones.")}
    end
  end

  def handle_event("abrir_editar_transicion", %{"id" => id}, socket) do
    t = Enum.find(socket.assigns.transiciones, &(&1.id == String.to_integer(id)))

    {:noreply,
     assign(socket, :transicion_form, %{
       "id" => t.id,
       "accion" => t.accion,
       "etiqueta" => t.etiqueta,
       "estado_origen_id" => t.estado_origen_id && to_string(t.estado_origen_id),
       "estado_destino_id" => to_string(t.estado_destino_id),
       "campos_editables" => t.campos_editables,
       "busqueda_campos" => %{},
       "error" => nil,
       "permisos" => permisos_transicion(socket.assigns.header, socket.assigns.catalogos_detalle, t.accion)
     })}
  end

  def handle_event("cerrar_form_transicion", _params, socket) do
    {:noreply, assign(socket, :transicion_form, nil)}
  end

  # Sin esto, una transición recién creada por la propia pantalla de
  # Reglas/Transiciones queda invisible/inejecutable para TODOS (ni el
  # administrador es un comodín, ver Permissions.can?/3) hasta que alguien
  # se acuerde de ir a Roles/Permission Sets a darla de alta a mano —
  # encontrado real con pty_crac_clientes (alta/baja/guardar/reactivar sin
  # ningún permiso registrado). Un click acá mismo, sin salir del modal.
  def handle_event("registrar_permiso_transicion", %{"recurso" => recurso}, socket) do
    accion = socket.assigns.transicion_form["accion"]
    # {:error, _} acá es casi siempre la unique_constraint (ya existe) —
    # mismo criterio que antes: cualquier resultado deja la fila marcada
    # "existe", el objetivo es que la fila esté, no reportar duplicados.
    Permissions.crear_permiso(%{"recurso" => recurso, "accion" => accion})

    {:noreply,
     update(socket, :transicion_form, fn form ->
       permisos = Enum.map(form["permisos"], &if(&1.recurso == recurso, do: %{&1 | existe: true}, else: &1))
       Map.put(form, "permisos", permisos)
     end)}
  end

  # --- Selector de campos editables por tab (Catálogo Maestro-Detalle) -----
  # "grupo" es "header" o el schema_context_name de un catálogo detalle —
  # mismo valor que la key del tab (ver tabs_motor en modal_transicion/1).
  def handle_event("buscar_campo_transicion", %{"grupo" => grupo, "value" => valor}, socket) do
    {:noreply,
     update(socket, :transicion_form, fn form ->
       busqueda = form |> Map.get("busqueda_campos", %{}) |> Map.put(grupo, valor)
       Map.put(form, "busqueda_campos", busqueda)
     end)}
  end

  def handle_event("marcar_todos_campos", %{"grupo" => grupo}, socket) do
    nombres = socket.assigns |> campos_del_grupo(grupo) |> Enum.map(& &1.schema_context_field)

    {:noreply,
     update(socket, :transicion_form, fn form ->
       actuales = Map.get(form, "campos_editables", [])
       Map.put(form, "campos_editables", Enum.uniq(actuales ++ nombres))
     end)}
  end

  def handle_event("desmarcar_todos_campos", %{"grupo" => grupo}, socket) do
    nombres = socket.assigns |> campos_del_grupo(grupo) |> MapSet.new(& &1.schema_context_field)

    {:noreply,
     update(socket, :transicion_form, fn form ->
       actuales = Map.get(form, "campos_editables", [])
       Map.put(form, "campos_editables", Enum.reject(actuales, &(&1 in nombres)))
     end)}
  end

  def handle_event("guardar_transicion", params, socket) do
    accion = String.trim(params["accion"] || "")
    campos_editables = params |> Map.get("campos_editables", []) |> List.wrap() |> Enum.reject(&(&1 == ""))

    attrs = %{
      "meta_schema_header_id" => socket.assigns.header.id,
      "accion" => accion,
      "etiqueta" => String.trim(params["etiqueta"] || ""),
      "estado_origen_id" => nil_si_vacio(params["estado_origen_id"]),
      "estado_destino_id" => params["estado_destino_id"],
      "campos_editables" => campos_editables
    }

    resultado =
      case params["registro_id"] do
        "" ->
          MetaEstadosAdmin.crear_transicion(attrs)

        id ->
          transicion = Enum.find(socket.assigns.transiciones, &(&1.id == String.to_integer(id)))
          MetaEstadosAdmin.actualizar_transicion(transicion, attrs)
      end

    case resultado do
      {:ok, _transicion} ->
        {:noreply,
         socket
         |> assign(:transicion_form, nil)
         |> put_flash(:info, "Transición \"#{accion}\" guardada.")
         |> cargar_motor()}

      {:error, changeset} ->
        {:noreply, update(socket, :transicion_form, &Map.put(&1, "error", resumen_errores(changeset)))}
    end
  end

  # eliminar_transicion/1 ya cascadea a sus propias reglas — no hace falta
  # ningún chequeo previo acá (a diferencia de estados, una transición no
  # es referenciada por nada más).
  def handle_event("eliminar_transicion", %{"id" => id}, socket) do
    transicion = Enum.find(socket.assigns.transiciones, &(&1.id == String.to_integer(id)))

    case MetaEstadosAdmin.eliminar_transicion(transicion) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Transición \"#{transicion.accion}\" eliminada.") |> cargar_motor()}

      {:error, _motivo} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar la transición.")}
    end
  end

  # --- Permisos de detalle por estado (insertar/actualizar/borrar renglones) --
  # Un click, un cambio inmediato (mismo criterio que toggle_permiso en
  # CatalogoPermisosLive) — sin form ni modal separado.
  def handle_event("toggle_permiso_detalle", %{"estado_id" => estado_id, "header_detalle_id" => header_detalle_id, "campo" => campo}, socket) do
    MetaEstadosAdmin.toggle_permiso_detalle(
      String.to_integer(estado_id),
      String.to_integer(header_detalle_id),
      String.to_existing_atom(campo)
    )

    {:noreply, cargar_motor(socket)}
  end

  # --- Compilar motor completo (tabla + reglas, un solo paso en dev/test) -----

  # Compila lo que YA está guardado en base para pre/post — "poner en línea
  # todo lo guardado hasta ahora". Si un tipo nunca se guardó, se omite sin
  # error (reglas no son obligatorias). Solo dev/test — recompilar_schema/1
  # necesita el .ex fuente en disco, que un release de producción no tiene.
  def handle_event("compilar_motor_completo", _params, socket) do
    header = socket.assigns.header
    :ok = CatalogoGenerador.recompilar_schema(header.schema_context_name)

    resultados =
      for tipo <- ~w(pre post), MetaReglasCodigo.obtener(header.id, tipo) do
        {tipo, MetaReglasCodigo.compilar(header, tipo)}
      end

    compiladas = for {tipo, {:ok, _modulo}} <- resultados, do: tipo
    errores = for {tipo, {:error, motivo}} <- resultados, do: "#{tipo}: #{motivo}"

    mensaje =
      case compiladas do
        [] -> "Tabla compilada. No había reglas guardadas todavía para compilar."
        _ -> "Tabla y reglas compiladas: #{Enum.join(compiladas, ", ")}."
      end

    socket = cargar_motor(socket)

    {:noreply,
     if errores == [] do
       put_flash(socket, :info, mensaje)
     else
       put_flash(socket, :error, "#{mensaje} Errores: #{Enum.join(errores, " | ")}")
     end}
  end

  # --- Reglas: código PRE/POST por catálogo -----------------------------------
  # Sin candado (retirado 2026-07-21 a pedido explícito): sin login real
  # todavía, un candado autodeclarado por nombre no era más que teatro de
  # seguridad — las reglas quedan siempre editables por cualquiera hasta
  # que exista autenticación de verdad. El resultado de cada acción queda
  # separado de cargar_motor/1 vía reglas_mensajes, así un mensaje de
  # éxito/error no se pierde en el siguiente recálculo.

  # Un solo botón "Compilar" (retirados Validar sintaxis/Guardar/Publicar
  # como acciones separadas — a pedido explícito, no aportaban nada que
  # "Compilar" no hiciera ya): valida sintaxis, si es válida guarda Y
  # compila; si no es válida, no guarda nada y avisa el error. "Publicar"
  # ya no vive acá — el commit real de las reglas va con
  # `mix motor.publicar <catalogo>` (que ya incluye la carpeta de reglas
  # completa) o el flujo normal de git+CI/CD, no un botón aparte en esta
  # pantalla. Un solo submit trae codigo_pre Y codigo_post, cada uno se
  # procesa por separado.
  def handle_event("reglas_compilar", params, socket) do
    codigos = %{"pre" => params["codigo_pre"] || "", "post" => params["codigo_post"] || ""}

    {socket, recargar?} =
      Enum.reduce(~w(pre post), {socket, false}, fn tipo, {socket, recargar_acc?} ->
        {socket, recargar?} = validar_guardar_y_compilar(socket, tipo, codigos[tipo])
        {socket, recargar_acc? or recargar?}
      end)

    {:noreply, if(recargar?, do: cargar_motor(socket), else: socket)}
  end

  defp validar_guardar_y_compilar(socket, tipo, codigo) do
    with :ok <- MetaReglasCodigo.validar_sintaxis(codigo),
         {:ok, _fila} <- MetaReglasCodigo.guardar(socket.assigns.header, tipo, codigo) do
      # push_event ANTES de mirar el resultado de compilar/2 a propósito:
      # guardar/3 ya persistió el código en base en los dos casos de abajo
      # (compile exitoso o "se guardó pero no compiló") — el aviso de
      # "salir sin guardar" del lado del cliente (AvisoReglasSinGuardar en
      # assets/js/app.js) tiene que bajar apenas deja de haber texto sin
      # persistir, no recién cuando compila limpio.
      socket = push_event(socket, "regla_guardada", %{tipo: tipo})

      case MetaReglasCodigo.compilar(socket.assigns.header, tipo) do
        {:ok, modulo} -> {put_reglas_mensaje(socket, tipo, {:info, "Guardado y compilado: #{inspect(modulo)}."}), true}
        {:error, motivo} -> {put_reglas_mensaje(socket, tipo, {:error, "Se guardó, pero no compiló: #{motivo}"}), true}
      end
    else
      {:error, motivo} -> {put_reglas_mensaje(socket, tipo, {:error, "Error de sintaxis: #{motivo}"}), false}
    end
  end

  defp put_reglas_mensaje(socket, tipo, mensaje) do
    update(socket, :reglas_mensajes, &Map.put(&1, tipo, mensaje))
  end

  defp modo_por_defecto("string"), do: "telefono"
  defp modo_por_defecto(tipo) when tipo in ["integer", "decimal"], do: "numero"
  defp modo_por_defecto(_tipo), do: "sin_mascara"

  # Patrón fijo de los presets no editables — "personalizada" es el único
  # modo donde el patrón sale de lo que tipeó quien configura el campo
  # (ver formato_cambiar/2 y construir_formato_captura/1 abajo, y
  # formato_ejemplo/2 que reusa esto mismo para la línea de ejemplo).
  defp patron_por_defecto("telefono"), do: "(999) 999-9999"
  defp patron_por_defecto("cp"), do: "99999"
  defp patron_por_defecto("rfc"), do: "AAAA999999AA9"
  defp patron_por_defecto("curp"), do: "AAAA999999AAAAAA*9"
  defp patron_por_defecto("fecha"), do: "99/99/9999"
  defp patron_por_defecto(_modo), do: nil

  defp to_entero_seguro(valor, default) when is_binary(valor) do
    case Integer.parse(valor) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp to_entero_seguro(_valor, default), do: default

  defp construir_formato_captura(%{"habilitada" => false}), do: {:ok, %{"habilitada" => false}}

  # "Número"/"Moneda" en un campo tipo "string" — a diferencia del caso
  # integer/decimal de abajo, acá SÍ aplica "guardar_formato" (la columna
  # es texto de verdad, puede persistir "1234.50" o "$1,234.50" tal cual).
  defp construir_formato_captura(%{"tipo" => "string", "modo" => modo} = form) when modo in ["numero", "moneda"] do
    {:ok,
     %{
       "habilitada" => true,
       "modo" => modo,
       "decimales" => form["decimales"],
       "separador_miles" => form["separador_miles"],
       "simbolo" => if(modo == "moneda", do: form["simbolo"]),
       "simbolo_posicion" => form["simbolo_posicion"],
       "permitir_negativos" => form["permitir_negativos"],
       "guardar_formato" => form["guardar_formato"],
       "estricto" => form["estricto"],
       "permitir_incompleto" => form["permitir_incompleto"],
       "mensaje_invalido" => form["mensaje_invalido"]
     }}
  end

  defp construir_formato_captura(%{"tipo" => "string"} = form) do
    cond do
      form["modo"] == "sin_mascara" ->
        {:ok, %{"habilitada" => false}}

      form["patron"] in [nil, ""] ->
        {:error, "Definí un patrón para la máscara."}

      true ->
        {:ok,
         %{
           "habilitada" => true,
           "modo" => form["modo"],
           "patron" => form["patron"],
           "guardar_formato" => form["guardar_formato"],
           "estricto" => form["estricto"],
           "permitir_incompleto" => form["permitir_incompleto"],
           "mensaje_invalido" => form["mensaje_invalido"]
         }}
    end
  end

  # integer/decimal: siempre numero/moneda — sin "guardar_formato", la
  # columna numérica real siempre guarda el número crudo.
  defp construir_formato_captura(form) do
    {:ok,
     %{
       "habilitada" => true,
       "modo" => form["modo"],
       "decimales" => form["decimales"],
       "separador_miles" => form["separador_miles"],
       "simbolo" => if(form["modo"] == "moneda", do: form["simbolo"]),
       "simbolo_posicion" => form["simbolo_posicion"],
       "permitir_negativos" => form["permitir_negativos"],
       "estricto" => form["estricto"],
       "permitir_incompleto" => form["permitir_incompleto"],
       "mensaje_invalido" => form["mensaje_invalido"]
     }}
  end

  # Compartido por los 3 toggle_mostrar_*_en_tabla/3 de arriba.
  defp toggle_columna_estructural(socket, campo, etiqueta) do
    header = socket.assigns.header
    valor = !Map.fetch!(header, campo)

    case MetaSchemaContext.actualizar_header(header, %{Atom.to_string(campo) => valor}) do
      {:ok, header_actualizado} -> {:noreply, socket |> assign(:header, header_actualizado) |> cargar_motor()}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo actualizar #{etiqueta}.")}
    end
  end

  # Compartido por cambiar_obligatorio_campo/2 y cambiar_valor_default_campo/2
  # — ambos necesitan CatalogoGenerador.generar/1 después de guardar
  # (a diferencia de cambiar_etiqueta_campo/2 y similares) porque tocan
  # @campos_requeridos/@campos_meta del schema compilado, no solo un dato
  # de presentación.
  defp actualizar_campo_y_regenerar(socket, detalle, props, etiqueta_error) do
    case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
      {:ok, _detalle} ->
        case CatalogoGenerador.generar(socket.assigns.header.schema_context_name) do
          {:ok, _resultado} ->
            {:noreply, cargar_motor(socket)}

          {:error, motivo} ->
            {:noreply,
             socket |> cargar_motor() |> put_flash(:error, "Se guardó, pero no se pudo regenerar el catálogo: #{motivo}")}
        end

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo actualizar #{etiqueta_error} de \"#{detalle.schema_context_field}\".")}
    end
  end

  defp guardar_campo_y_generar(socket, header, nombre, propiedades) do
    case MetaSchemaContext.agregar_detalle(header, %{"schema_context_field" => nombre, "schema_context_properties" => propiedades}) do
      {:ok, _detalle} ->
        case CatalogoGenerador.generar(header.schema_context_name) do
          {:ok, _resultado} ->
            {:noreply,
             socket
             |> assign(:campo_form, nil)
             |> put_flash(:info, "Campo \"#{nombre}\" agregado.")
             |> cargar_motor()}

          {:error, motivo} ->
            {:noreply,
             update(socket, :campo_form, &Map.put(&1, "error", "Campo guardado pero no se pudo generar la columna: #{motivo}"))}
        end

      {:error, changeset} ->
        {:noreply, update(socket, :campo_form, &Map.put(&1, "error", resumen_errores(changeset)))}
    end
  end


  defp normalizar_icono(valor) do
    (valor || "")
    |> String.trim()
    |> String.downcase()
    |> quitar_acentos()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 50)
  end

  defp quitar_acentos(valor) do
    valor
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  defp nil_si_vacio(""), do: nil
  defp nil_si_vacio(valor), do: valor

  # Antes hacía inspect/1 del mapa crudo de traverse_errors — mostraba algo
  # como "%{meta_schema_header_id: [\"has already been taken\"]}" en el
  # banner de error del modal, ilegible para un usuario real. Ahora arma un
  # texto plano "campo: mensaje" (mismo criterio que ya usan otras pantallas
  # de este proyecto para errores de changeset).
  defp resumen_errores(changeset), do: MetadataApp.MetaErrores.resumen(changeset)

  # "sin_configurar" (default de abrir_form_relacion/1 cuando el campo
  # nunca tuvo campo_visualizacion) borra la llave entera en vez de
  # guardar el modo tal cual — así un catálogo que nunca tocó esta sección
  # sigue funcionando 100% con campos_acompanamiento, sin ninguna llave
  # nueva en la base (retrocompatibilidad real, no solo "vacío").
  defp aplicar_campo_visualizacion(props, %{"modo" => "sin_configurar"}), do: Map.delete(props, "campo_visualizacion")
  defp aplicar_campo_visualizacion(props, config), do: Map.put(props, "campo_visualizacion", config)

  defp registro_muestra_de(catalogo) do
    case MetaSchemaContext.modulo_por_nombre(catalogo) do
      nil ->
        nil

      modulo ->
        # :sistema (Fase 4a) -- registro de muestra para el Constructor,
        # no un listado real para un usuario final.
        case CatalogoGenerico.listar(modulo, :sistema, %{}, limit: 1) do
          [registro] -> registro
          [] -> nil
        end
    end
  end

  # Antes, una relación nunca tocada arrancaba en "sin_configurar" (el
  # modal viejo lo mostraba como un <select> más, sin vista previa) — la
  # premisa de este modal nuevo es que SIEMPRE haya algo que mostrar
  # apenas se abre, así que arranca en "descripcion" con el primer campo
  # visible del catálogo relacionado ya elegido (casi siempre es el
  # "nombre" o equivalente). Se puede cambiar de una — esto es solo el
  # punto de partida, nunca se persiste hasta que alguien aprieta Guardar.
  defp campo_visualizacion_por_defecto([]), do: %{"modo" => "descripcion"}

  defp campo_visualizacion_por_defecto([primero | _resto]),
    do: %{"modo" => "descripcion", "campo_descripcion" => primero.schema_context_field}

  # Ícono cosmético por campo para las columnas 1/2 del modal — primero
  # por patrones comunes de nombre de negocio (más específico y más útil
  # a simple vista que el tipo real), si no matchea nada cae al tipo real
  # del campo (campo_input/1 sigue siendo la única fuente de verdad de qué
  # tipo ES un campo; esto es solo decorativo).
  defp icono_campo(campo) do
    nombre = campo.schema_context_field
    tipo = campo.schema_context_properties["tipo"]

    cond do
      String.contains?(nombre, "telefono") -> "call"
      String.contains?(nombre, ["correo", "email"]) -> "mail"
      String.contains?(nombre, "direccion") -> "location_on"
      String.contains?(nombre, ["representante", "contacto", "responsable", "ejecutivo"]) -> "person"
      tipo == "referencia" -> "link"
      tipo in ["integer", "decimal"] -> "tag"
      tipo == "date" -> "calendar_month"
      tipo == "hora" -> "schedule"
      tipo == "boolean" -> "toggle_on"
      tipo == "texto_largo" -> "notes"
      tipo == "enum" -> "list"
      true -> "text_fields"
    end
  end

  # Agrupa una lista de campos por su categoría real (MetaSchemaContext.
  # categoria_campo/1 — la misma que ya se configura en "Campos" arriba,
  # nunca una taxonomía inventada para este modal). Si TODOS caen en la
  # misma categoría (catálogo chico, nadie configuró categorías todavía)
  # se devuelve un único grupo SIN etiqueta — una sola sección de
  # acordeón no aporta nada, mejor una lista plana.
  defp agrupar_campos(campos) do
    agrupados =
      campos
      |> Enum.group_by(&MetaSchemaContext.categoria_campo/1)
      |> Enum.map(fn {codigo, campos_grupo} -> {MetaSchemaContext.etiqueta_categoria_campo(codigo), campos_grupo} end)
      |> Enum.sort_by(fn {etiqueta, _campos} -> etiqueta end)

    case agrupados do
      [{_etiqueta, campos_unicos}] -> [{nil, campos_unicos}]
      varios -> varios
    end
  end

  # --- Tab API: ejemplos de payload por verbo ---------------------------------
  # Documentación generada a partir de los campos REALES del catálogo (no
  # texto fijo) — CatalogoController (lib/metadata_app_web/controllers/
  # business_process_builder/catalogo_controller.ex) es el mismo para
  # cualquier catálogo, así que lo que cambia entre uno y otro es solo esto.

  # Un valor representativo por tipo — no busca ser realista, solo mostrar
  # la FORMA que Postgres/Ecto esperan para ese tipo en el JSON.
  defp valor_ejemplo_campo(propiedades) do
    case Map.get(propiedades, "tipo", "string") do
      "string" -> "texto"
      "integer" -> 1
      "decimal" -> 10.5
      "boolean" -> true
      "date" -> "2026-01-15"
      "hora" -> "14:30"
      "texto_largo" -> "texto largo…"
      "enum" -> (propiedades |> Map.get("valores", ["valor_a"]) |> List.first()) || "valor_a"
      "referencia" -> 1
      _ -> "texto"
    end
  end

  # Body de POST/PATCH: solo los campos de negocio (nunca "id" ni
  # "estado_id" — ver MetaCatalogoGenerico.__using__/1: estado_id está
  # deliberadamente fuera de @campos, el único camino para cambiarlo es la
  # transición correspondiente, no un PATCH directo).
  defp ejemplo_payload(campos) do
    Map.new(campos, &{&1.schema_context_field, valor_ejemplo_campo(&1.schema_context_properties)})
  end

  # Alta atómica (R6): el ejemplo de creación de un maestro incluye
  # "renglones" con DOS items de ejemplo por cada catálogo detalle (nunca
  # uno solo) — a propósito, para que quede visualmente obvio que es una
  # lista donde van tantos renglones como el pedido necesite (2, 10, 50 —
  # sin límite, ver MetadataApp.Renglones.crear_todos/3), no un campo fijo
  # de "un solo renglón". Sin renglon_id (son altas nuevas, el motor lo
  # asigna solo). [] de catalogos_detalle = mismo payload de siempre, sin
  # la llave.
  defp ejemplo_payload_con_renglones(campos, []), do: ejemplo_payload(campos)

  defp ejemplo_payload_con_renglones(campos, catalogos_detalle) do
    renglones =
      Map.new(catalogos_detalle, fn %{schema_context_name: nombre, campos: campos_detalle} ->
        {nombre, [ejemplo_payload(campos_detalle), ejemplo_payload(campos_detalle)]}
      end)

    Map.put(ejemplo_payload(campos), "renglones", renglones)
  end

  # "data" tal cual lo arma CatalogoGenerico.serializar/2: id + todos los
  # campos + estado_id/estado_nombre si el catálogo adoptó el motor.
  defp ejemplo_registro(campos, estados) do
    base = Map.put(ejemplo_payload(campos), "id", 1)

    case Enum.find(estados, & &1.es_inicial) || List.first(estados) do
      nil -> base
      estado -> base |> Map.put("estado_id", estado.id) |> Map.put("estado_nombre", estado.nombre)
    end
  end

  # Un Map chico de Elixir NO conserva el orden en que se escribió en el
  # código — Jason.encode!/2 itera el orden interno del VM (ninguna
  # garantía, no es alfabético ni de inserción, se verificó a mano). Para
  # que "id" salga primero de verdad en los ejemplos de esta pestaña, hay
  # que forzarlo con Jason.OrderedObject — recursivo porque hay mapas
  # anidados (ej. {"data": {"id": ..., ...}} o listas de registros).
  defp json_pretty(dato), do: dato |> id_primero() |> Jason.encode!(pretty: true)

  defp id_primero(mapa) when is_map(mapa) do
    {con_id, resto} = Enum.split_with(mapa, fn {k, _v} -> to_string(k) == "id" end)
    Jason.OrderedObject.new(Enum.map(con_id ++ resto, fn {k, v} -> {k, id_primero(v)} end))
  end

  defp id_primero(lista) when is_list(lista), do: Enum.map(lista, &id_primero/1)
  defp id_primero(valor), do: valor

  # --- Render ------------------------------------------------------------------

  def render(%{header: nil} = assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-8">
      <p class="text-sm text-gray-600">Ese catálogo ya no existe (puede que alguien más lo haya borrado).</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto p-6 text-xs font-sans space-y-4">
      <div class="flex items-start justify-between gap-4">
        <div class="flex items-start gap-2">
          <.link navigate={~p"/sysadmin/bc-list"} title="Volver al listado de BC"
            class="mt-0.5 w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0">
            <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
          </.link>
          <div>
            <h1 class="text-lg font-bold text-gray-900">{@header.schema_context_label}</h1>
            <p class="mt-0.5 text-gray-500">
              <span class="font-mono">{@header.schema_context_name}</span>
              <span class="mx-1.5 text-gray-300">·</span>
              <span class="font-mono">{@header.schema_context_nav}</span>
            </p>
          </div>
        </div>
        <div class="shrink-0 flex items-start gap-2">
          <div :if={@compilar_disponible} class="flex flex-col items-center">
            <button type="button" phx-click="compilar_motor_completo"
              class="px-4 py-2 rounded-lg bg-blue-600 text-white font-bold hover:bg-blue-700 transition-colors">
              Compila Todo
            </button>
            <span class="mt-1 text-[10px] text-gray-400">Recompila tabla + reglas (modo dev)</span>
          </div>
        </div>
      </div>

      <%!-- Catálogo Maestro-Detalle (R3): un catálogo detalle nunca tiene
           autómata ni contrato de API propios — comparte el del maestro
           (ver docs/catalogo-maestro-detalle-requerimientos.md). Se avisa
           acá arriba de todo, con link directo al maestro, en vez de dejar
           que el usuario descubra el candado recorriendo tabs vacíos. --%>
      <div :if={@es_detalle?} class="bg-blue-50 border border-blue-200 text-blue-800 rounded-lg px-3 py-2">
        <p>
          Este catálogo es <strong>detalle de {@maestro.schema_context_label}</strong> — comparte su autómata (sin
          estados/transiciones propias) y no tiene contrato de API independiente: sus campos y renglones se
          documentan dentro del contrato del maestro.
          <.link navigate={~p"/sysadmin/bc-list/#{@maestro.schema_context_name}/motor"} class="font-semibold text-blue-900 hover:underline">
            Ver {@maestro.schema_context_label} →
          </.link>
        </p>
      </div>

      <.motor_stepper pasos={pasos_motor(@completitud, @transiciones, @es_detalle?, @header, @campos)} />
      <.panel_problemas :if={@validacion.problemas != []} problemas={@validacion.problemas} />

      <.tabs_motor id="motor" tabs={
        [
          %{key: "config", label: "Configuración"},
          %{key: "reglas", label: "Reglas"}
        ] ++
          if(@es_detalle?,
            do: [],
            else: [
              %{key: "diagrama", label: "Diagrama"},
              %{key: "api", label: "Contrato"},
              %{key: "permisos", label: "Permisos"}
            ]
          ) ++
          [
            %{key: "get", label: "Relaciones"},
            %{key: "getview", label: "Vista Get"},
            %{key: "postview", label: "Vista Post"}
          ]
      } />

      <div id="motor-panel-config" class="space-y-4">
        <.panel_encabezado header_form={@header_form} iconos_sugeridos={@iconos_sugeridos} carpetas={@carpetas} />
        <.panel_campos campos={@campos} />
        <%= if @es_detalle? do %>
          <div class="border border-gray-200 rounded-lg p-3 text-gray-500">
            Sin estados/transiciones propias — este catálogo se mueve junto con <strong>{@maestro.schema_context_label}</strong>.
          </div>
        <% else %>
          <.tabla_estados estados={@estados} transiciones={@transiciones} puede_agregar={@completitud.tiene_campos} />
          <.tabla_transiciones transiciones={@transiciones} estados_por_id={@estados_por_id} catalogo={@header.schema_context_name}
            puede_agregar={@completitud.tiene_estados and @completitud.tiene_alta_o_inicial} />
        <% end %>
      </div>

      <div id="motor-panel-reglas" class="hidden">
        <.panel_reglas header={@header} reglas={@reglas} reglas_mensajes={@reglas_mensajes}
          compilar_disponible={@compilar_disponible} />
      </div>

      <div id="motor-panel-getview" class="hidden">
        <.panel_get_view campos={@campos} header={@header} />
        <.panel_filtros_resumen campos={@campos} />
        <.panel_campos_default header={@header} />
        <.panel_filtros_default header={@header} />
      </div>

      <div id="motor-panel-get" class="hidden">
        <.panel_relaciones campos={@campos} />
      </div>

      <%= unless @es_detalle? do %>
        <div id="motor-panel-diagrama" class="hidden">
          <.diagrama_transiciones diagrama={@diagrama} />
        </div>

        <div id="motor-panel-api" class="hidden">
          <.panel_api header={@header} campos={@campos} estados={@estados} transiciones={@transiciones} />
        </div>

        <!-- Embebido como LiveView hijo (live_render/3), mismo criterio que
             "PostView" más abajo — antes era el link "Permisos" en BcListLive
             que navegaba a /sysadmin/catalogos/:recurso/permisos; ahora vive
             como tab acá, sin saltar de página. El recurso viaja por
             session (un hijo montado por live_render nunca recibe params
             reales del router) — ver la cláusula de mount/3 en
             CatalogoPermisosLive que matchea session %{"recurso" => ...}. -->
        <div id="motor-panel-permisos" class="hidden space-y-4">
          {live_render(@socket, MetadataAppWeb.Sysadmin.CatalogoPermisosLive,
            id: "permisos-embebido-#{@header.schema_context_name}",
            session: %{"recurso" => @header.schema_context_name}
          )}
          <.tabla_permisos_detalle :if={@catalogos_detalle != []} estados={@estados} catalogos_detalle={@catalogos_detalle} permisos_detalle={@permisos_detalle} />
        </div>
      <% end %>

      <!-- Embebido como LiveView hijo (live_render/3, sin merge de código
           con PlantillaConstructorLive) en vez de navegar a
           /sysadmin/bc-list/:nombre/plantilla como antes — así "PostView"
           se ve dentro de este mismo tablero, como cualquier otro tab, sin
           saltar de página. La sesión del proceso hijo se identifica por
           `schema_context_name`: cambiar de catálogo (otra página de
           BcMotorLive) monta una instancia nueva, nunca reusa estado
           viejo. Vive fuera del div "hidden"/"visible" de los demás tabs
           a propósito (con id propio ya alcanza para que tabs_motor lo
           muestre/oculte igual que a los demás). -->
      <div id="motor-panel-postview" class="hidden">
        {live_render(@socket, MetadataAppWeb.Sysadmin.PlantillaConstructorLive,
          id: "plantilla-embebido-#{@header.schema_context_name}",
          session: %{"nombre" => @header.schema_context_name}
        )}
      </div>
    </div>

    <FieldDesignerComponents.asistente :if={@campo_form} form={@campo_form} catalogos={@catalogos_referenciables} nombre_base={@header.schema_context_name} campos={@campos} />
    <.modal_eliminar_campo :if={@eliminar_campo_form} form={@eliminar_campo_form} />
    <.modal_estado :if={@estado_form} form={@estado_form} />
    <.modal_transicion :if={@transicion_form} form={@transicion_form} estados={@estados} campos={@campos} catalogos_detalle={@catalogos_detalle} />
    <.modal_relacion :if={@relacion_form} form={@relacion_form} local_label={@header.schema_context_label} />
    <.modal_dependencia :if={@dependencia_form} form={@dependencia_form} />
    <.modal_formato_captura :if={@formato_form} form={@formato_form} />
    """
  end

  # Genera la definición Mermaid (stateDiagram-v2) del autómata — un [*] por
  # cada estado inicial y por cada transición sin estado_origen ("alta"),
  # más un arco por transición. Los nombres de estado se declaran con alias
  # cortos (e1, e2...) en vez de usarlos directo como id del nodo: soporta
  # cualquier nombre con espacios/acentos sin arriesgar la sintaxis de
  # Mermaid, que es estricta con los identificadores de nodo.
  defp diagrama_mermaid(estados, transiciones) do
    alias_por_id = estados |> Enum.with_index(1) |> Map.new(fn {e, i} -> {e.id, "e#{i}"} end)

    declaraciones =
      Enum.map(estados, fn e -> ~s(    state "#{e.orden} - #{escapar_mermaid(e.nombre)}" as #{Map.fetch!(alias_por_id, e.id)}) end)

    iniciales =
      estados
      |> Enum.filter(& &1.es_inicial)
      |> Enum.map(&"    [*] --> #{Map.fetch!(alias_por_id, &1.id)}")

    arcos =
      Enum.map(transiciones, fn t ->
        origen = if t.estado_origen_id, do: Map.get(alias_por_id, t.estado_origen_id, "?"), else: "[*]"
        destino = Map.get(alias_por_id, t.estado_destino_id, "?")
        "    #{origen} --> #{destino} : #{escapar_mermaid(t.accion)}"
      end)

    estilos =
      estados
      |> Enum.filter(& &1.color)
      |> Enum.map(&estilo_color(Map.fetch!(alias_por_id, &1.id), &1.color))

    (["stateDiagram-v2"] ++ declaraciones ++ iniciales ++ arcos ++ estilos) |> Enum.join("\n")
  end

  defp escapar_mermaid(texto), do: String.replace(texto || "", "\"", "")

  # El color que se elige por Estado (mismo hex que ya se ve como puntito
  # en la tabla de Estados) se aplica de verdad al nodo del diagrama, no
  # solo a la tabla — Mermaid soporta `style <id> fill:...` igual que en un
  # flowchart. El color de texto se calcula por luminancia (fórmula
  # estándar YIQ) para que siga siendo legible tanto sobre un fill oscuro
  # como uno claro, en vez de asumir uno fijo.
  defp estilo_color(id_nodo, color_hex) do
    "    style #{id_nodo} fill:#{color_hex},stroke:#{color_hex},color:#{color_texto_legible(color_hex)}"
  end

  defp color_texto_legible(color_hex) do
    case hex_a_rgb(color_hex) do
      {r, g, b} ->
        luminancia = 0.299 * r + 0.587 * g + 0.114 * b
        if luminancia > 150, do: "#111827", else: "#ffffff"

      :error ->
        "#111827"
    end
  end

  defp hex_a_rgb("#" <> resto) when byte_size(resto) == 6 do
    case Integer.parse(resto, 16) do
      {n, ""} -> {div(n, 65536), n |> div(256) |> rem(256), rem(n, 256)}
      _ -> :error
    end
  end

  defp hex_a_rgb(_), do: :error

  # Orden real en que se arma el autómata — mismos booleanos que ya
  # calculaba completitud/1, solo reordenados en una secuencia lógica
  # (antes vivían como chips sueltos sin orden: Campos, Estado Inicial,
  # Tiene Estados...). "Transiciones" no es un campo propio de
  # completitud/1, se deriva acá: hay al menos una Y ninguna es un
  # self-loop sin campos editables configurados.
  # Catálogo Maestro-Detalle (R3): sin pasos de autómata — un catálogo
  # detalle nunca tiene estados/transiciones propias, mostrarlos como
  # "pendientes" para siempre sería engañoso (nunca se van a completar,
  # ni hace falta que lo hagan). Sí tiene Relaciones/Vista Get/Vista Post
  # (campos propios, get view propio) — Permisos no, un detalle nunca
  # tiene permisos aparte (los de la fila los da su maestro), mismo
  # criterio que ya regía el viejo link "Permisos" de BcListLive.
  defp pasos_motor(completitud, _transiciones, true, header, campos) do
    ([
       {"Campos", completitud.tiene_campos},
       {"Reglas", not completitud.reglas.pre_pendiente and not completitud.reglas.post_pendiente}
     ] ++ pasos_opcionales(header, campos, incluir_permisos?: false))
    |> marcar_estado_pasos()
  end

  defp pasos_motor(completitud, transiciones, false, header, campos) do
    tiene_transiciones? = transiciones != [] and completitud.transiciones_self_loop_sin_campos_editables == 0

    # "Estado inicial" antes que "Estados" (invertido 2026-07-21, a pedido
    # explícito): ahora coinciden siempre en el mismo momento — el primer
    # Estado que se crea ya nace forzado como inicial (ver
    # MetaEstadosAdmin.crear_estado/1) — el orden nuevo refleja que
    # establecer el inicial es lo que de verdad importa primero, no una
    # etapa separada que viene después de tener "estados" en plural.
    ([
       {"Campos", completitud.tiene_campos},
       {"Estado inicial", completitud.tiene_alta_o_inicial},
       {"Estados", completitud.tiene_estados},
       {"Transiciones", tiene_transiciones?},
       {"Reglas", not completitud.reglas.pre_pendiente and not completitud.reglas.post_pendiente}
     ] ++ pasos_opcionales(header, campos, incluir_permisos?: true))
    |> marcar_estado_pasos()
  end

  # Permisos/Relaciones/Vista Get/Vista Post (2026-08-04, a pedido
  # explícito): a diferencia de los pasos de arriba, estos NO son
  # obligatorios para que el catálogo funcione — son configuración
  # opcional que, si nadie la tocó todavía, no debería bloquear ni
  # ensuciar el stepper. Por eso cada uno se OMITE del todo (no aparece
  # en la lista) mientras no aplique, en vez de contar como "pendiente"
  # — mismo criterio que ya usa pasos_motor/5 para un catálogo detalle
  # (arriba: Estado inicial/Estados/Transiciones directamente no
  # existen ahí). Permisos/Vista Get/Vista Post se muestran ya
  # completos apenas hay algo configurado (no hay un estado intermedio
  # "a medias" para ellos); Relaciones es la excepción — se muestra
  # justo cuando FALTA algo (al menos un campo referencia sin
  # campo_visualizacion ni campos_acompanamiento), y desaparece solo
  # cuando ya no queda ninguno sin configurar.
  defp pasos_opcionales(header, campos, incluir_permisos?: incluir_permisos?) do
    referencias_sin_configurar = Enum.count(campos, &(campo_referencia?(&1) and not campo_referencia_configurado?(&1)))
    tiene_algo_oculto? = Enum.any?(campos, &(get_in(&1.schema_context_properties, ["visible"]) == false))
    tiene_plantilla? = MetaPlantillas.listar_plantillas(header.id) != []

    (if incluir_permisos? and Permissions.tiene_permisos_concedidos?(header.schema_context_name),
       do: [{"Permisos", true}],
       else: []) ++
      (if referencias_sin_configurar > 0, do: [{"Relaciones", false}], else: []) ++
      (if tiene_algo_oculto?, do: [{"Vista Get", true}], else: []) ++
      (if tiene_plantilla?, do: [{"Vista Post", true}], else: [])
  end

  defp campo_referencia?(campo), do: get_in(campo.schema_context_properties, ["tipo"]) == "referencia"

  defp campo_referencia_configurado?(campo) do
    props = campo.schema_context_properties
    (is_map(props["campo_visualizacion"]) and props["campo_visualizacion"] != %{}) or
      (is_list(props["campos_acompanamiento"]) and props["campos_acompanamiento"] != [])
  end

  # El primer paso todavía no completo es "donde estás parado" (:actual) —
  # todo lo anterior ya quedó atrás (:completo), todo lo posterior todavía
  # no aplica (:pendiente). Se recalcula siempre desde los booleanos reales,
  # no desde en qué panel se hizo click último.
  defp marcar_estado_pasos(pasos) do
    primero_pendiente_idx = Enum.find_index(pasos, fn {_label, ok?} -> not ok? end)

    pasos
    |> Enum.with_index()
    |> Enum.map(fn {{label, ok?}, idx} ->
      estado =
        cond do
          ok? -> :completo
          primero_pendiente_idx == idx -> :actual
          true -> :pendiente
        end

      %{label: label, estado: estado}
    end)
  end

  attr :problemas, :list, required: true

  defp panel_problemas(assigns) do
    ~H"""
    <div class="space-y-1">
      <%= for problema <- @problemas do %>
        <div class={[
          "flex items-start gap-1.5 px-2.5 py-1.5 rounded-lg",
          problema.severidad == :error && "bg-red-50 text-red-700",
          problema.severidad == :advertencia && "bg-amber-50 text-amber-700"
        ]}>
          <span class="font-bold uppercase text-[10px] pt-0.5">
            {if problema.severidad == :error, do: "Error", else: "Aviso"}
          </span>
          <span>{problema.mensaje}</span>
        </div>
      <% end %>
    </div>
    """
  end

  attr :header_form, :map, required: true
  attr :iconos_sugeridos, :list, required: true
  attr :carpetas, :list, required: true

  defp panel_encabezado(assigns) do
    assigns = assign(assigns, :nav_preview, componer_nav_header(assigns.header_form["carpeta_padre"], assigns.header_form["segmento"]))

    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Encabezado</span>
      </div>
      <div class="p-3 pt-4">
        <%= if @header_form["error"] do %>
          <div class="bg-red-50 text-red-700 rounded-lg px-2 py-1.5 mb-2">{@header_form["error"]}</div>
        <% end %>

        <form phx-change="validar_header" phx-submit="guardar_header" class="grid grid-cols-[100px_1fr] gap-y-2 gap-x-2 items-center">
          <label class="font-medium text-gray-900">Etiqueta:</label>
          <input type="text" name="header[etiqueta]" value={@header_form["etiqueta"]} required maxlength="100"
            class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />

          <label class="font-medium text-gray-900">Navegación:</label>
          <div>
            <div class="flex items-center gap-1">
              <select name="header[carpeta_padre]"
                title="Solo carpetas que ya existen en el menú — así no se puede tipear una ruta con errores ni pisar la de otro catálogo."
                class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500">
                <option value="" selected={@header_form["carpeta_padre"] in [nil, ""]}>— Sin carpeta (raíz) —</option>
                <%= for carpeta <- @carpetas do %>
                  <option value={carpeta.ruta} selected={@header_form["carpeta_padre"] == carpeta.ruta}>{carpeta.etiqueta}</option>
                <% end %>
              </select>
              <span class="text-gray-400">/</span>
              <input type="text" name="header[segmento]" value={@header_form["segmento"]} required maxlength="50"
                title="Solo el segmento final de este catálogo — sin espacios ni '/'."
                class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 flex-1 font-mono focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />
            </div>
            <div class="mt-1 bg-purple-50 border border-purple-200 text-purple-700 rounded-lg px-1.5 py-0.5 inline-flex items-center gap-1">
              <span class="text-purple-400">Vista previa:</span>
              <span class="font-mono">{@nav_preview}</span>
            </div>
          </div>

          <label class="font-medium text-gray-900">Ícono:</label>
          <div>
            <input type="hidden" name="header[icono]" value={@header_form["icono"]} />
            <button type="button" phx-click={JS.toggle(to: "#selector-iconos-header")}
              class="w-6 h-6 flex items-center justify-center border border-gray-300 rounded-lg bg-gray-50 hover:bg-gray-100 text-gray-700 transition-colors" title="Elegir ícono">
              <%= if @header_form["icono"] not in [nil, ""] do %>
                <span class="material-symbols-outlined" style="font-size: 16px">{@header_form["icono"]}</span>
              <% else %>
                <span class="material-symbols-outlined text-gray-400" style="font-size: 16px">apps</span>
              <% end %>
            </button>

            <div id="selector-iconos-header" class="hidden mt-1 border border-gray-200 rounded-lg bg-white shadow-lg p-1.5 max-w-md">
              <div class="grid grid-cols-10 gap-0.5 max-h-40 overflow-y-auto">
                <%= for icono <- @iconos_sugeridos do %>
                  <button type="button" title={icono}
                    phx-click={JS.push("elegir_icono_header", value: %{icono: icono}) |> JS.hide(to: "#selector-iconos-header")}
                    class={[
                      "w-6 h-6 flex items-center justify-center rounded-lg text-gray-700 hover:bg-purple-50 hover:text-purple-700 transition-colors",
                      @header_form["icono"] == icono && "bg-purple-100 text-purple-700"
                    ]}>
                    <span class="material-symbols-outlined" style="font-size: 16px">{icono}</span>
                  </button>
                <% end %>
              </div>
            </div>
          </div>

          <div></div>
          <label class="flex items-center gap-1.5 font-medium text-gray-900 cursor-pointer select-none">
            <input type="hidden" name="header[visible]" value="false" />
            <input type="checkbox" name="header[visible]" value="true" checked={@header_form["visible"] == true} class="accent-purple-600" />
            Es visible
          </label>

          <div></div>
          <div>
            <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 transition-colors">
              Guardar encabezado
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :campos, :list, required: true

  defp panel_campos(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Campos</span>
      </div>
      <div class="p-3 pt-4 overflow-x-auto">
        <%= if @campos == [] do %>
          <p class="text-gray-400 mb-2">Este catálogo todavía no tiene campos.</p>
        <% else %>
          <table class="min-w-full mb-2">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-1.5 py-1 border-b border-gray-200"></th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Nombre</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Etiqueta</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Tipo</th>
                <th class="px-1.5 py-1 text-center font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200" title="Solo validación de la app (el formulario no deja guardar vacío) — la columna en la base de datos se queda nullable siempre">Obligatorio</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200" title="Si el campo obligatorio llega vacío, se rellena con este valor en vez de rechazar el guardado">Default</th>
                <th class="px-1.5 py-1 text-center font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200" title="Si aparece como columna en la tabla del tab Detalle de la Ficha 360° — el formulario de al lado siempre muestra todos los campos, esto es solo la tabla">En tabla</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200" title="Máscara de texto (teléfono, RFC, personalizada…) o formato numérico/moneda (decimales, separador de miles, negativos)">Formato</th>
                <th class="px-1.5 py-1 border-b border-gray-200"></th>
              </tr>
            </thead>
            <tbody id="tabla-campos-ordenable" phx-hook="ListaOrdenable" data-grupo="campos-catalogo">
              <%= for c <- @campos do %>
                <% props = c.schema_context_properties || %{} %>
                <tr id={"campos-row-#{c.schema_context_field}"} class="border-b border-gray-100 hover:bg-gray-50" data-id={c.schema_context_field}>
                  <td class="px-1.5 py-1 text-gray-300 jal-manija cursor-grab" title="Arrastrar para reordenar">
                    <span class="material-symbols-outlined" style="font-size: 16px">drag_indicator</span>
                  </td>
                  <td class="px-1.5 py-1 text-gray-900 font-mono">{c.schema_context_field}</td>
                  <td class="px-1.5 py-1">
                    <form phx-change="cambiar_etiqueta_campo">
                      <input type="hidden" name="campo" value={c.schema_context_field} />
                      <input type="text" name="etiqueta" value={Map.get(props, "etiqueta")} maxlength="100" required
                        class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] text-gray-700 w-full min-w-[110px]" />
                    </form>
                  </td>
                  <td class="px-1.5 py-1 text-gray-600">
                    <%= if Map.get(props, "tipo") == "referencia" do %>
                      <span class="inline-flex items-center gap-0.5 bg-blue-50 text-blue-700 rounded-full px-1.5 py-0.5 font-semibold" title={"Relación con #{Map.get(props, "catalogo")}"}>
                        <span class="material-symbols-outlined" style="font-size: 12px">link</span>
                        referencia
                      </span>
                    <% else %>
                      {Map.get(props, "tipo")}
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1 text-center">
                    <form phx-change="cambiar_obligatorio_campo">
                      <input type="hidden" name="campo" value={c.schema_context_field} />
                      <input type="hidden" name="obligatorio" value="false" />
                      <input type="checkbox" name="obligatorio" value="true" checked={Map.get(props, "opcional") != true} class="accent-purple-600" />
                    </form>
                  </td>
                  <td class="px-1.5 py-1">
                    <%= if Map.get(props, "opcional") != true and Map.get(props, "tipo") != "referencia" do %>
                      <form phx-change="cambiar_valor_default_campo">
                        <input type="hidden" name="campo" value={c.schema_context_field} />
                        <input type="text" name="valor_default" value={Map.get(props, "valor_default")}
                          title="Valor si es nulo"
                          class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] text-gray-700 w-11" />
                      </form>
                    <% else %>
                      <span class="text-gray-300">—</span>
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1 text-center">
                    <form phx-change="cambiar_mostrar_en_tabla">
                      <input type="hidden" name="campo" value={c.schema_context_field} />
                      <input type="hidden" name="mostrar_en_tabla" value="false" />
                      <input type="checkbox" name="mostrar_en_tabla" value="true" checked={MetaSchemaContext.mostrar_en_tabla?(props)} class="accent-purple-600" />
                    </form>
                  </td>
                  <td class="px-1.5 py-1">
                    <%= if Map.get(props, "tipo") in ["string", "integer", "decimal"] do %>
                      <button type="button" phx-click="abrir_form_formato" phx-value-campo={c.schema_context_field}
                        class="text-purple-600 hover:text-purple-800 text-[11px] font-semibold">
                        <%= if get_in(props, ["formato_captura", "habilitada"]) == true, do: "Configurado", else: "Configurar" %>
                      </button>
                    <% else %>
                      <span class="text-gray-300">—</span>
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1">
                    <button type="button" phx-click="abrir_eliminar_campo" phx-value-campo={c.schema_context_field}
                      class="text-red-600 hover:text-red-800 text-[11px] font-semibold">Eliminar</button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>

        <button type="button" phx-click="abrir_form_campo" class="text-purple-700 hover:text-purple-900 font-semibold">
          + Agregar campo
        </button>
      </div>
    </div>
    """
  end

  attr :campos, :list, required: true

  # Relaciones: qué campos de OTRO catálogo (el referenciado) trae de
  # prestado cada campo tipo "referencia" de este — ver
  # docs/roadmap-campos-acompanamiento.md. El campo local tiene que
  # existir YA como tipo "referencia" (se crea en el panel Campos de
  # arriba, eligiendo catálogo destino) — acá solo se elige QUÉ trae.
  defp panel_relaciones(assigns) do
    referencias = Enum.filter(assigns.campos, &(get_in(&1.schema_context_properties, ["tipo"]) == "referencia"))
    assigns = assign(assigns, :referencias, referencias)

    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Relaciones</span>
      </div>
      <div class="p-3 pt-4 overflow-x-auto">
        <%= if @referencias == [] do %>
          <p class="text-gray-400">
            Este catálogo no tiene ningún campo tipo <span class="font-mono">referencia</span> todavía — agrega uno en "Campos" (arriba), eligiendo a qué catálogo apunta, para poder configurar acá qué trae de prestado.
          </p>
        <% else %>
          <table class="min-w-full mb-2">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Campo local</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Catálogo destino</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Campos que trae</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Campos que muestra allá</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200" title="Combo en cascada: qué otro campo referencia de este catálogo tiene que elegirse primero">Depende de</th>
                <th class="px-1.5 py-1 border-b border-gray-200"></th>
              </tr>
            </thead>
            <tbody>
              <%= for c <- @referencias do %>
                <% props = c.schema_context_properties %>
                <% traidos = Map.get(props, "campos_acompanamiento", []) %>
                <% mostrados = Map.get(props, "campos_relacion", []) %>
                <% dependencias = Map.get(props, "dependencias", []) %>
                <tr class="border-b border-gray-100 hover:bg-gray-50">
                  <td class="px-1.5 py-1 text-gray-900 font-mono">{c.schema_context_field}</td>
                  <td class="px-1.5 py-1 text-gray-700 font-mono">{Map.get(props, "catalogo")}</td>
                  <td class="px-1.5 py-1 text-gray-600">
                    <%= if traidos == [] do %>
                      <span class="text-gray-400">sin configurar</span>
                    <% else %>
                      {Enum.join(traidos, ", ")}
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1 text-gray-600">
                    <%= if mostrados == [] do %>
                      <span class="text-gray-400">sin configurar</span>
                    <% else %>
                      {Enum.join(mostrados, ", ")}
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1 text-gray-600">
                    <%= if dependencias == [] do %>
                      <span class="text-gray-400">—</span>
                    <% else %>
                      {dependencias |> Enum.map(& &1["campo_padre"]) |> Enum.join(" + ")}
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1 whitespace-nowrap">
                    <button type="button" phx-click="abrir_form_relacion" phx-value-campo={c.schema_context_field}
                      class="text-blue-600 hover:text-blue-800 text-[11px] font-semibold mr-2">Configurar</button>
                    <button type="button" phx-click="abrir_form_dependencia" phx-value-campo={c.schema_context_field}
                      class="text-purple-600 hover:text-purple-800 text-[11px] font-semibold">Cascada</button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  attr :campos, :list, required: true
  attr :header, :any, required: true

  # "Get View": qué campos ve el usuario final al consultar este catálogo
  # (tabla de CatalogoLive) — expone TODOS los campos reales, marcados
  # según su propiedad "visible" actual en el contrato, para que se puedan
  # prender/apagar de un vistazo sin tener que editar campo por campo.
  defp panel_get_view(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Get View</span>
      </div>
      <div class="p-3 pt-4 overflow-x-auto">
        <p class="text-gray-500 mb-2">
          Qué campos ve el usuario final en la tabla de este catálogo. Desmarcar un campo no lo borra ni afecta la API — solo lo oculta de la vista.
        </p>

        <div class="flex flex-wrap gap-2 mb-3">
          <button type="button" phx-click="toggle_mostrar_id_en_tabla"
            class={[
              "text-[11px] font-semibold rounded-lg px-3 py-1.5 transition-colors whitespace-nowrap",
              if(@header.mostrar_id_en_tabla, do: "bg-purple-600 text-white", else: "bg-purple-100 text-purple-700 hover:bg-purple-200")
            ]}>
            {if @header.mostrar_id_en_tabla, do: "✓ ID", else: "ID (oculto)"}
          </button>
          <button type="button" phx-click="toggle_mostrar_estado_en_tabla"
            class={[
              "text-[11px] font-semibold rounded-lg px-3 py-1.5 transition-colors whitespace-nowrap",
              if(@header.mostrar_estado_en_tabla, do: "bg-purple-600 text-white", else: "bg-purple-100 text-purple-700 hover:bg-purple-200")
            ]}>
            {if @header.mostrar_estado_en_tabla, do: "✓ Estado", else: "Estado (oculto)"}
          </button>
          <button type="button" phx-click="toggle_mostrar_trn_en_tabla"
            class={[
              "text-[11px] font-semibold rounded-lg px-3 py-1.5 transition-colors whitespace-nowrap",
              if(@header.mostrar_trn_en_tabla, do: "bg-purple-600 text-white", else: "bg-purple-100 text-purple-700 hover:bg-purple-200")
            ]}>
            {if @header.mostrar_trn_en_tabla, do: "✓ TRN", else: "TRN (oculto)"}
          </button>
        </div>
        <p class="text-gray-400 text-[11px] mb-3">
          Columnas de sistema — Estado/TRN solo aparecen igual si el catálogo tiene motor de estados / es transaccional, esto solo los oculta encima de eso.
        </p>

        <%= if @campos == [] do %>
          <p class="text-gray-400">Este catálogo todavía no tiene campos.</p>
        <% else %>
          <form id="get-view-form" phx-submit="guardar_get_view">
            <div class="flex items-center justify-between gap-2 mb-2">
              <div class="flex gap-2">
                <button type="button"
                  onclick="this.closest('form').querySelectorAll('input[type=checkbox]').forEach(cb => cb.checked = true)"
                  class="text-purple-700 hover:text-purple-900 text-[11px] font-semibold">
                  Seleccionar todos
                </button>
                <span class="text-gray-300">|</span>
                <button type="button"
                  onclick="this.closest('form').querySelectorAll('input[type=checkbox]').forEach(cb => cb.checked = false)"
                  class="text-purple-700 hover:text-purple-900 text-[11px] font-semibold">
                  Deseleccionar todos
                </button>
              </div>
              <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 transition-colors">
                Guardar Get View
              </button>
            </div>
            <table class="min-w-full mb-2">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-1.5 py-1 border-b border-gray-200"></th>
                  <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Nombre</th>
                  <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Etiqueta</th>
                  <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Tipo</th>
                  <th class="px-1.5 py-1 text-center font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Visible al usuario</th>
                </tr>
              </thead>
              <tbody id="tabla-get-view-ordenable" phx-hook="ListaOrdenable" data-grupo="campos-catalogo-getview">
                <%= for c <- @campos do %>
                  <% props = c.schema_context_properties || %{} %>
                  <tr id={"getview-row-#{c.schema_context_field}"} class="border-b border-gray-100 hover:bg-gray-50" data-id={c.schema_context_field}>
                    <td class="px-1.5 py-1 text-gray-300 jal-manija cursor-grab" title="Arrastrar para reordenar">
                      <span class="material-symbols-outlined" style="font-size: 16px">drag_indicator</span>
                    </td>
                    <td class="px-1.5 py-1 text-gray-900 font-mono">{c.schema_context_field}</td>
                    <td class="px-1.5 py-1 text-gray-700">{Map.get(props, "etiqueta")}</td>
                    <td class="px-1.5 py-1 text-gray-600">{Map.get(props, "tipo")}</td>
                    <td class="px-1.5 py-1 text-center">
                      <input type="checkbox" name="visibles[]" value={c.schema_context_field}
                        checked={Map.get(props, "visible") == true} class="accent-purple-600" />
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </form>
        <% end %>
      </div>
    </div>
    """
  end

  # "Filtros": qué campos participan de la fila de Resumen de CatalogoLive
  # (Suma/Promedio/Conteo si son numéricos, Conteo si no) — sección aparte
  # de la tabla de Get View de arriba, a propósito: un campo real (ej.
  # "cantidad", con su Nombre/Etiqueta/Tipo/Visible) es simplemente un
  # dato de la tabla, no tiene nada que ver con esto. Acá se arma una
  # lista aparte: de TODOS los campos del catálogo (dinámico, según
  # existan — "referencia" queda afuera porque en la fila el valor real
  # es un id de otra tabla, no algo que sumar/contar de forma útil),
  # cuáles participan del Resumen ("+ Agregar filtro") y cuáles de esos
  # además muestran mínimo/máximo ("Mín. Máx.") — CatalogoLive decide qué
  # funciones ofrecer según el tipo real de cada uno (ver celdas_resumen/1
  # ahí).
  attr :campos, :list, required: true

  defp panel_filtros_resumen(assigns) do
    agregables = Enum.filter(assigns.campos, &(get_in(&1.schema_context_properties, ["tipo"]) != "referencia"))
    activos = Enum.filter(agregables, &(get_in(&1.schema_context_properties, ["agregacion_activa"]) == true))
    disponibles = agregables -- activos

    assigns =
      assigns
      |> assign(:filtros_activos, activos)
      |> assign(:campos_disponibles, disponibles)
      |> assign(:hay_numericos?, Enum.any?(activos, &(get_in(&1.schema_context_properties, ["tipo"]) in ["integer", "decimal"])))

    ~H"""
    <div class="border border-gray-200 rounded-lg mt-4">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Filtros</span>
      </div>
      <div class="p-3 pt-4 overflow-x-auto">
        <p class="text-gray-500 mb-2">
          Qué campos calculan un total en la fila de Resumen del catálogo — Suma/Promedio/Conteo si el campo es numérico, Conteo si no. "Mín. Máx.", "Total 25" y "Totalizado" solo aplican a campos numéricos (integer/decimal).
        </p>

        <%= if @filtros_activos == [] do %>
          <p class="text-gray-400 mb-2">Todavía no agregaste ningún filtro.</p>
        <% else %>
          <table class="min-w-full mb-3">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Campo</th>
                <th :if={@hay_numericos?} class="px-1.5 py-1 text-center font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Mín. Máx.</th>
                <th :if={@hay_numericos?} class="px-1.5 py-1 text-center font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Total 25</th>
                <th :if={@hay_numericos?} class="px-1.5 py-1 text-center font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Totalizado</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Valor por default</th>
                <th class="px-1.5 py-1 text-center font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Bloqueado</th>
                <th class="px-1.5 py-1 border-b border-gray-200"></th>
              </tr>
            </thead>
            <tbody>
              <%= for c <- @filtros_activos do %>
                <% props = c.schema_context_properties || %{} %>
                <% recomendado? = Map.get(props, "minmax_recomendado") == true %>
                <% tipo = Map.get(props, "tipo") %>
                <% numerico? = tipo in ["integer", "decimal"] %>
                <% total_pagina? = Map.get(props, "total_pagina_activo") == true %>
                <% total_general? = Map.get(props, "total_general_activo") == true %>
                <% bloqueado? = Map.get(props, "filtro_default_bloqueado") == true %>
                <tr class="border-b border-gray-100 hover:bg-gray-50">
                  <td class="px-1.5 py-1 text-gray-900">{Map.get(props, "etiqueta") || c.schema_context_field}</td>
                  <td :if={@hay_numericos?} class="px-1.5 py-1 text-center">
                    <%= if numerico? do %>
                      <button type="button"
                        phx-click="cambiar_minmax_recomendado"
                        phx-value-campo={c.schema_context_field}
                        phx-value-recomendado={to_string(!recomendado?)}
                        title="Mostrar siempre el mínimo y el máximo en la fila de Resumen del catálogo"
                        class={[
                          "text-[9px] font-semibold uppercase tracking-wide rounded-full px-2 py-0.5 transition-colors",
                          if(recomendado?, do: "bg-green-600 text-white", else: "bg-red-100 text-red-700 hover:bg-red-200")
                        ]}
                      >
                        Mín. Máx.
                      </button>
                    <% else %>
                      <span class="text-gray-300 text-[11px]">—</span>
                    <% end %>
                  </td>
                  <td :if={@hay_numericos?} class="px-1.5 py-1 text-center">
                    <%= if numerico? do %>
                      <button type="button"
                        phx-click="cambiar_total_pagina"
                        phx-value-campo={c.schema_context_field}
                        phx-value-activo={to_string(!total_pagina?)}
                        title="Mostrar la suma de SOLO los registros de la página actual (25) en la fila de Resumen"
                        class={[
                          "text-[9px] font-semibold uppercase tracking-wide rounded-full px-2 py-0.5 transition-colors",
                          if(total_pagina?, do: "bg-green-600 text-white", else: "bg-red-100 text-red-700 hover:bg-red-200")
                        ]}
                      >
                        Total 25
                      </button>
                    <% else %>
                      <span class="text-gray-300 text-[11px]">—</span>
                    <% end %>
                  </td>
                  <td :if={@hay_numericos?} class="px-1.5 py-1 text-center">
                    <%= if numerico? do %>
                      <button type="button"
                        phx-click="cambiar_total_general"
                        phx-value-campo={c.schema_context_field}
                        phx-value-activo={to_string(!total_general?)}
                        title="Mostrar la suma de TODOS los registros que matchean el filtro/búsqueda actual, no solo la página"
                        class={[
                          "text-[9px] font-semibold uppercase tracking-wide rounded-full px-2 py-0.5 transition-colors",
                          if(total_general?, do: "bg-green-600 text-white", else: "bg-red-100 text-red-700 hover:bg-red-200")
                        ]}
                      >
                        Totalizado
                      </button>
                    <% else %>
                      <span class="text-gray-300 text-[11px]">—</span>
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1">
                    <%= if tipo == "boolean" do %>
                      <form phx-change="cambiar_filtro_valor_default">
                        <input type="hidden" name="campo" value={c.schema_context_field} />
                        <select name="valor" class="text-[11px] border border-gray-300 rounded px-1.5 py-1">
                          <option value="" selected={Map.get(props, "filtro_default_valor", "") == ""}>Cualquiera</option>
                          <option value="true" selected={Map.get(props, "filtro_default_valor") == "true"}>Sí</option>
                          <option value="false" selected={Map.get(props, "filtro_default_valor") == "false"}>No</option>
                        </select>
                      </form>
                    <% else %>
                      <%= if tipo in ["integer", "decimal", "date"] do %>
                        <div class="flex items-center gap-1">
                          <form phx-change="cambiar_filtro_rango_default">
                            <input type="hidden" name="campo" value={c.schema_context_field} />
                            <input type="hidden" name="extremo" value="desde" />
                            <input
                              type={if tipo == "date", do: "date", else: "number"}
                              name="valor"
                              placeholder="Desde"
                              value={Map.get(props, "filtro_default_desde")}
                              class="w-24 text-[11px] border border-gray-300 rounded px-1.5 py-1"
                            />
                          </form>
                          <span class="text-gray-300">–</span>
                          <form phx-change="cambiar_filtro_rango_default">
                            <input type="hidden" name="campo" value={c.schema_context_field} />
                            <input type="hidden" name="extremo" value="hasta" />
                            <input
                              type={if tipo == "date", do: "date", else: "number"}
                              name="valor"
                              placeholder="Hasta"
                              value={Map.get(props, "filtro_default_hasta")}
                              class="w-24 text-[11px] border border-gray-300 rounded px-1.5 py-1"
                            />
                          </form>
                        </div>
                      <% else %>
                        <form phx-change="cambiar_filtro_valor_default">
                          <input type="hidden" name="campo" value={c.schema_context_field} />
                          <input
                            type="text"
                            name="valor"
                            placeholder="Cualquiera"
                            value={Map.get(props, "filtro_default_valor")}
                            class="text-[11px] border border-gray-300 rounded px-1.5 py-1 w-full"
                          />
                        </form>
                      <% end %>
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1 text-center">
                    <button type="button"
                      phx-click="cambiar_filtro_bloqueado"
                      phx-value-campo={c.schema_context_field}
                      phx-value-bloqueado={to_string(!bloqueado?)}
                      title="El usuario final no puede cambiar ni quitar este filtro — solo agregar otros aparte"
                      class={[
                        "text-[9px] font-semibold uppercase tracking-wide rounded-full px-2 py-0.5 transition-colors",
                        if(bloqueado?, do: "bg-red-600 text-white", else: "bg-gray-100 text-gray-500 hover:bg-gray-200")
                      ]}
                    >
                      <%= if bloqueado?, do: "🔒 Bloqueado", else: "Bloquear" %>
                    </button>
                  </td>
                  <td class="px-1.5 py-1 text-center">
                    <button type="button"
                      phx-click="quitar_filtro_resumen"
                      phx-value-campo={c.schema_context_field}
                      class="text-red-600 hover:text-red-800 text-[11px] font-semibold"
                    >
                      Quitar
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>

        <%= if @campos_disponibles != [] do %>
          <form phx-submit="agregar_filtro_resumen" class="flex items-center gap-2">
            <select name="campo" class="border border-gray-300 rounded-lg px-2 py-1.5">
              <%= for c <- @campos_disponibles do %>
                <option value={c.schema_context_field}>{Map.get(c.schema_context_properties, "etiqueta") || c.schema_context_field}</option>
              <% end %>
            </select>
            <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 transition-colors">
              + Agregar filtro
            </button>
          </form>
        <% else %>
          <p :if={@filtros_activos != []} class="text-gray-400">Ya agregaste todos los campos numéricos disponibles.</p>
        <% end %>
      </div>
    </div>
    """
  end

  # "Filtros por default": qué ve el usuario final apenas ABRE la tabla
  # del catálogo, antes de elegir nada — aparte de "Filtros" de arriba
  # (que calcula Suma/Promedio/Conteo, no filtra filas). Dos opciones
  # INDEPENDIENTES entre sí (una no depende de la otra prendida, cada una
  # se puede usar sola o las dos juntas), cada una en su propia caja:
  #   - "Campos por default": trae TODOS los registros y columnas sin
  #     esperar filtro/búsqueda.
  #   - "Filtros por default": acota por fecha de alta (ver Header y
  #     MetaAuditoria.ids_creados_en_rango/3 — los catálogos generados no
  #     tienen columna de timestamp propia, se resuelve vía auditoría).
  attr :header, :any, required: true

  defp panel_campos_default(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg mt-4">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Campos por default</span>
      </div>
      <div class="p-3 pt-4 overflow-x-auto">
        <p class="text-gray-500 mb-3">
          Trae todos los registros y columnas apenas se abre la tabla, sin esperar un filtro o búsqueda primero. El usuario final igual puede filtrar después con los filtros normales de la tabla.
        </p>

        <button type="button"
          phx-click="toggle_cargar_todos_por_default"
          class={[
            "text-[11px] font-semibold rounded-lg px-3 py-1.5 transition-colors whitespace-nowrap",
            if(@header.cargar_todos_por_default, do: "bg-purple-600 text-white", else: "bg-purple-100 text-purple-700 hover:bg-purple-200")
          ]}
        >
          <%= if @header.cargar_todos_por_default do %>
            ✓ Campos por default — Quitar
          <% else %>
            + Campos por default
          <% end %>
        </button>
      </div>
    </div>
    """
  end

  attr :estados, :list, required: true
  attr :transiciones, :list, required: true
  attr :puede_agregar, :boolean, required: true

  defp tabla_estados(assigns) do
    referenciados =
      MapSet.new(assigns.transiciones, & &1.estado_origen_id)
      |> MapSet.union(MapSet.new(assigns.transiciones, & &1.estado_destino_id))

    assigns = assign(assigns, :referenciados, referenciados)

    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Estados</span>
      </div>
      <div class="p-3 pt-4 overflow-x-auto">
        <%= if @estados == [] do %>
          <p class="text-gray-400">Este catálogo todavía no tiene estados definidos.</p>
        <% else %>
          <table class="min-w-full">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200"></th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Nombre</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Inicial</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Orden</th>
                <th class="px-1.5 py-1 border-b border-gray-200"></th>
              </tr>
            </thead>
            <tbody>
              <%= for estado <- @estados do %>
                <tr class="border-b border-gray-100 hover:bg-gray-50">
                  <td class="px-1.5 py-1">
                    <%= if estado.icono do %>
                      <span class="material-symbols-outlined" style={"font-size: 16px; color: #{estado.color || "#6b7280"}"}>{estado.icono}</span>
                    <% else %>
                      <span class="inline-block w-2.5 h-2.5 rounded-full" style={"background: #{estado.color || "#d1d5db"}"}></span>
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1 text-gray-900">{estado.nombre}</td>
                  <td class="px-1.5 py-1">
                    <%= if estado.es_inicial do %>
                      <span class="text-purple-700 font-semibold">Sí</span>
                    <% else %>
                      <span class="text-gray-400">—</span>
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1 text-gray-600">{estado.orden}</td>
                  <td class="px-1.5 py-1 whitespace-nowrap">
                    <button type="button" phx-click="abrir_editar_estado" phx-value-id={estado.id} class="text-blue-600 hover:text-blue-800 text-[11px] font-semibold mr-2">
                      Editar
                    </button>
                    <%= if not MapSet.member?(@referenciados, estado.id) do %>
                      <button type="button" phx-click="eliminar_estado" phx-value-id={estado.id}
                        data-confirm={"¿Eliminar el estado \"#{estado.nombre}\"?"}
                        class="text-red-600 hover:text-red-800 text-[11px] font-semibold">
                        Eliminar
                      </button>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>

        <button type="button" phx-click="abrir_form_estado" disabled={!@puede_agregar}
          class="text-purple-700 hover:text-purple-900 font-semibold disabled:text-gray-300 disabled:cursor-not-allowed">
          + Agregar estado
        </button>
        <span :if={!@puede_agregar} class="text-gray-400 ml-1">(agregá al menos un campo primero)</span>
      </div>
    </div>
    """
  end

  attr :transiciones, :list, required: true
  attr :estados_por_id, :map, required: true
  attr :catalogo, :string, required: true
  attr :puede_agregar, :boolean, required: true

  defp tabla_transiciones(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Transiciones</span>
      </div>
      <div class="p-3 pt-4 overflow-x-auto">
        <%= if @transiciones == [] do %>
          <p class="text-gray-400">Este catálogo todavía no tiene transiciones definidas.</p>
        <% else %>
          <table class="min-w-full">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Acción</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Etiqueta</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Origen → Destino</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Campos editables</th>
                <th class="px-1.5 py-1 border-b border-gray-200"></th>
              </tr>
            </thead>
            <tbody>
              <%= for t <- @transiciones do %>
                <% self_loop? = t.estado_origen_id != nil and t.estado_origen_id == t.estado_destino_id %>
                <% aviso? = self_loop? and t.campos_editables == [] %>
                <tr class={["border-b border-gray-100 hover:bg-gray-50 align-top", aviso? && "bg-amber-50/60"]}>
                  <td class="px-1.5 py-1.5 text-gray-900 font-mono">
                    {t.accion}
                    <%= if aviso? do %>
                      <span
                        class="material-symbols-outlined text-amber-600 align-middle"
                        style="font-size: 13px"
                        title="Self-loop sin campos_editables — cualquier intento de editar por acá va a fallar"
                      >warning</span>
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1.5 text-gray-700">{t.etiqueta}</td>
                  <td class="px-1.5 py-1.5 text-gray-600">
                    {nombre_estado(@estados_por_id, t.estado_origen_id) || "— (alta)"}
                    <span class="text-gray-300 mx-1">→</span>
                    {nombre_estado(@estados_por_id, t.estado_destino_id) || "?"}
                  </td>
                  <td class="px-1.5 py-1.5 text-gray-600">
                    <%= if t.campos_editables == [] do %>
                      <span class="text-gray-300">—</span>
                    <% else %>
                      <span title={Enum.join(t.campos_editables, ", ")}>{length(t.campos_editables)} campo(s)</span>
                    <% end %>
                  </td>
                  <td class="px-1.5 py-1.5 whitespace-nowrap">
                    <button type="button" phx-click="abrir_editar_transicion" phx-value-id={t.id} class="text-blue-600 hover:text-blue-800 text-[11px] font-semibold mr-2">
                      Editar
                    </button>
                    <button type="button" phx-click="eliminar_transicion" phx-value-id={t.id}
                      data-confirm={"¿Eliminar la transición \"#{t.accion}\"?"}
                      class="text-red-600 hover:text-red-800 text-[11px] font-semibold">
                      Eliminar
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>

        <button type="button" phx-click="abrir_form_transicion" disabled={!@puede_agregar}
          class="text-purple-700 hover:text-purple-900 font-semibold disabled:text-gray-300 disabled:cursor-not-allowed">
          + Agregar transición
        </button>
        <span :if={!@puede_agregar} class="text-gray-400 ml-1">(definí un estado inicial primero)</span>
      </div>
    </div>
    """
  end

  defp nombre_estado(_mapa, nil), do: nil
  defp nombre_estado(mapa, id), do: Map.get(mapa, id, %{nombre: "?"}).nombre

  # Permisos de detalle por estado (insertar/actualizar/borrar renglones):
  # capa nueva e independiente del permiso RBAC de transición — una fila
  # por Estado (igual que tabla_estados), y para cada catálogo detalle 3
  # toggles (Insertar/Actualizar/Borrar). Deny-by-default: sin fila en
  # @permisos_detalle, los 3 se muestran apagados (ver
  # MetaEstadosAdmin.permiso_detalle/2, misma regla en tiempo de ejecución).
  attr :estados, :list, required: true
  attr :catalogos_detalle, :list, required: true
  attr :permisos_detalle, :map, required: true

  defp tabla_permisos_detalle(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Permisos de detalle</span>
      </div>
      <div class="p-3 pt-4 overflow-x-auto">
        <%= if @estados == [] do %>
          <p class="text-gray-400">Definí estados primero.</p>
        <% else %>
          <table class="min-w-full">
            <thead class="bg-gray-50">
              <tr>
                <th rowspan="2" class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200 align-bottom">Estado</th>
                <th :for={detalle <- @catalogos_detalle} colspan="3" class="px-1.5 py-1 text-center font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-l border-gray-200">
                  {detalle.etiqueta}
                </th>
              </tr>
              <tr>
                <%= for _detalle <- @catalogos_detalle do %>
                  <th class="px-1 py-1 text-center font-medium text-[10px] text-gray-400 border-b border-l border-gray-200">Insertar</th>
                  <th class="px-1 py-1 text-center font-medium text-[10px] text-gray-400 border-b border-gray-200">Actualizar</th>
                  <th class="px-1 py-1 text-center font-medium text-[10px] text-gray-400 border-b border-gray-200">Borrar</th>
                <% end %>
              </tr>
            </thead>
            <tbody>
              <tr :for={estado <- @estados} class="border-b border-gray-100 hover:bg-gray-50">
                <td class="px-1.5 py-1 text-gray-900 whitespace-nowrap">{estado.nombre}</td>
                <%= for detalle <- @catalogos_detalle do %>
                  <% permiso = Map.get(@permisos_detalle, {estado.id, detalle.id}, %{permite_insertar: false, permite_actualizar: false, permite_borrar: false}) %>
                  <td class="px-1 py-1 text-center border-l border-gray-100"><.toggle_permiso_detalle estado_id={estado.id} header_detalle_id={detalle.id} campo="permite_insertar" concedido={permiso.permite_insertar} /></td>
                  <td class="px-1 py-1 text-center"><.toggle_permiso_detalle estado_id={estado.id} header_detalle_id={detalle.id} campo="permite_actualizar" concedido={permiso.permite_actualizar} /></td>
                  <td class="px-1 py-1 text-center"><.toggle_permiso_detalle estado_id={estado.id} header_detalle_id={detalle.id} campo="permite_borrar" concedido={permiso.permite_borrar} /></td>
                <% end %>
              </tr>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  attr :estado_id, :integer, required: true
  attr :header_detalle_id, :integer, required: true
  attr :campo, :string, required: true
  attr :concedido, :boolean, required: true

  defp toggle_permiso_detalle(assigns) do
    ~H"""
    <button type="button" phx-click="toggle_permiso_detalle" phx-value-estado_id={@estado_id} phx-value-header_detalle_id={@header_detalle_id} phx-value-campo={@campo}
      class={[
        "w-5 h-5 rounded border inline-flex items-center justify-center",
        @concedido && "bg-purple-600 border-purple-600 text-white" || "bg-white border-gray-300 hover:bg-gray-50"
      ]}
    >
      <span :if={@concedido} class="material-symbols-outlined" style="font-size: 13px">check</span>
    </button>
    """
  end

  attr :diagrama, :string, required: true

  # phx-update="ignore": una vez que el hook pinta el SVG de Mermaid adentro,
  # este contenedor queda congelado para LiveView — sin esto, cualquier
  # re-render de la página (ej. un flash) borraría el SVG ya renderizado, ya
  # que el servidor solo sabe de un <div> vacío con el data-diagrama.
  defp diagrama_transiciones(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Diagrama</span>
      </div>
      <div class="p-3 pt-4">
        <div
          id="diagrama-motor"
          phx-hook="DiagramaMotor"
          phx-update="ignore"
          data-diagrama={@diagrama}
          class="flex items-center justify-center min-h-[80px] text-gray-400"
        >
          Cargando diagrama…
        </div>
      </div>
    </div>
    """
  end

  attr :header, :map, required: true
  attr :reglas, :map, required: true
  attr :reglas_mensajes, :map, required: true
  attr :compilar_disponible, :boolean, required: true

  # Un solo <form> envuelve los dos textareas (PRE y POST) y un solo botón
  # "Compilar" — retirados Validar sintaxis/Guardar/Publicar como acciones
  # separadas a pedido explícito (ver validar_guardar_y_compilar/3).
  # Compilar solo existe en dev/test; sin eso no hay forma de que editar
  # acá sirva de algo (nada se compila en un release de producción), así
  # que ahí el bloque queda de solo lectura con una nota.
  defp panel_reglas(assigns) do
    ~H"""
    <div class="space-y-4">
      <form phx-submit="reglas_compilar" class="space-y-4">
        <div :if={@compilar_disponible} class="flex items-center gap-2 border border-gray-200 rounded-lg p-2 bg-gray-50">
          <span class="text-gray-500 mr-1">Aplica a PRE y POST:</span>
          <button type="submit" class="px-3 py-1.5 rounded-lg bg-blue-600 text-white font-semibold hover:bg-blue-700">
            Compilar
          </button>
          <span class="text-gray-400">Valida sintaxis, guarda y compila — si hay error, no guarda nada.</span>
        </div>
        <p :if={!@compilar_disponible} class="text-gray-500 border border-gray-200 rounded-lg p-2 bg-gray-50">
          Edición solo disponible en dev/test — en producción se llega a través de git + release, no desde esta pantalla.
        </p>

        <.tabs_motor id="reglas" tabs={[
          %{key: "pre", label: "PRECONDICIONES"},
          %{key: "post", label: "POSCONDICIONES"}
        ]} />

        <div id="reglas-panel-pre">
          <.bloque_regla tipo="pre" titulo="PRE — antes de aplicar la transición (el primer error frena todo)" header={@header}
            fila={@reglas["pre"]} mensaje={@reglas_mensajes["pre"]} compilar_disponible={@compilar_disponible} />
        </div>

        <div id="reglas-panel-post" class="hidden">
          <.bloque_regla tipo="post" titulo="POST — después de aplicar la transición (si falla, se deshace todo)" header={@header}
            fila={@reglas["post"]} mensaje={@reglas_mensajes["post"]} compilar_disponible={@compilar_disponible} />
        </div>
      </form>
    </div>
    """
  end

  attr :tipo, :string, required: true
  attr :titulo, :string, required: true
  attr :header, :map, required: true
  attr :fila, :any, required: true
  attr :mensaje, :any, required: true
  attr :compilar_disponible, :boolean, required: true

  defp bloque_regla(assigns) do
    fila = assigns.fila
    codigo = if fila, do: fila.codigo_fuente, else: MetaReglasCodigo.generar_stub(assigns.header, assigns.tipo)
    pendiente = String.contains?(codigo, MetaReglasCodigo.marcador_stub())
    sin_compilar = assigns.compilar_disponible and not MetaReglasCodigo.sincronizado?(assigns.header, assigns.tipo)
    {mensaje_tipo, mensaje_texto} = assigns.mensaje || {nil, nil}

    assigns =
      assigns
      |> assign(:nombre_campo, "codigo_#{assigns.tipo}")
      |> assign(:codigo, codigo)
      |> assign(:pendiente, pendiente)
      |> assign(:sin_compilar, sin_compilar)
      |> assign(:mensaje_tipo, mensaje_tipo)
      |> assign(:mensaje_texto, mensaje_texto)

    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">{@titulo}</span>
      </div>
      <div class="p-3 pt-4 space-y-2">
        <div :if={@mensaje_tipo} class={[
          "rounded-lg px-2 py-1.5",
          @mensaje_tipo == :error && "bg-red-50 text-red-700",
          @mensaje_tipo == :info && "bg-green-50 text-green-700"
        ]}>{@mensaje_texto}</div>

        <div :if={@pendiente or @sin_compilar} class="flex items-center gap-2">
          <span :if={@pendiente} class="text-amber-600">Tiene marcadores sin completar (#ESCRIBA SU CODIGO AQUÍ)</span>
          <span :if={@sin_compilar} class="text-blue-600">Guardado sin compilar — el motor corre la versión anterior</span>
        </div>

        <div class="flex justify-end">
          <button type="button" phx-hook="CopiarTextarea" id={"copiar-#{@nombre_campo}"} data-target={@nombre_campo}
            class="text-purple-700 font-semibold hover:underline" title="Copiar la regla completa al portapapeles">
            Copiar
          </button>
        </div>

        <textarea id={@nombre_campo} name={@nombre_campo} readonly={!@compilar_disponible} rows="14" spellcheck="false"
          phx-hook={if @compilar_disponible, do: "AvisoReglasSinGuardar"} data-tipo={@tipo}
          class={[
          "w-full border rounded-lg px-2 py-1.5 font-mono text-[11px] leading-relaxed",
          @compilar_disponible && "border-gray-300 bg-white text-gray-900",
          !@compilar_disponible && "border-gray-200 bg-gray-50 text-gray-500"
        ]}>{@codigo}</textarea>
      </div>
    </div>
    """
  end

  attr :header, :map, required: true
  attr :campos, :list, required: true
  attr :estados, :list, required: true
  attr :transiciones, :list, required: true

  # Sin PATCH/DELETE (retirados 2026-07-21 a pedido explícito): la mayoría
  # de la carga real es por lotes vía POST, y editar campos ahora es
  # responsabilidad de las transiciones (ver ejecutar_transicion/3en
  # MetaStateEngine, extendido el mismo día para aplicar campos_editables
  # junto con el cambio de estado, un solo POST). Se documenta acá el
  # descubrimiento (GET) y CADA transición real configurada, con su
  # payload si tiene campos editables — nunca un ejemplo genérico que
  # "funciona siempre" y esconde que el 422 depende del estado actual.
  defp panel_api(assigns) do
    tabla = assigns.header.schema_context_name
    registro = ejemplo_registro(assigns.campos, assigns.estados)
    meta_campos = Enum.map(assigns.campos, &%{"schema_context_field" => &1.schema_context_field, "schema_context_properties" => &1.schema_context_properties})
    estados_por_id = Map.new(assigns.estados, &{&1.id, &1.nombre})

    # Catálogo Maestro-Detalle (Fase 4, R7/R10) — catálogos detalle de ESTE
    # maestro, con sus propios campos, para poder documentar el payload
    # compuesto ("renglones") y el bloque meta_campos_detalle del GET.
    # [] para la enorme mayoría de catálogos (sin detalles) — nada de lo
    # de abajo cambia en ese caso.
    catalogos_detalle =
      assigns.header.id
      |> MetaSchemaContext.listar_catalogos_detalle()
      |> Enum.map(&%{schema_context_name: &1.schema_context_name, campos: MetaSchemaContext.listar_detalles(&1.schema_context_name)})

    meta_campos_detalle =
      Map.new(catalogos_detalle, fn %{schema_context_name: nombre, campos: campos_detalle} ->
        {nombre, Enum.map(campos_detalle, &%{"schema_context_field" => &1.schema_context_field, "schema_context_properties" => &1.schema_context_properties})}
      end)

    # "Todos los renglones de un pedido" (pregunta real de usuario): antes
    # no había forma de filtrar el GET genérico por query string — se
    # documenta acá, junto al resto de lo que un catálogo detalle no
    # documenta por su cuenta (no tiene pestaña Contrato propia).
    renglones_detalle_doc =
      Enum.map(catalogos_detalle, fn %{schema_context_name: nombre, campos: campos_detalle} ->
        meta_campos_d = Enum.map(campos_detalle, &%{"schema_context_field" => &1.schema_context_field, "schema_context_properties" => &1.schema_context_properties})

        ejemplo_renglon =
          ejemplo_payload(campos_detalle)
          |> Map.merge(%{"id" => 1, "encabezado_id" => 1, "renglon_id" => 1, "estado_id" => 1, "estado_nombre" => "Borrador"})

        respuesta =
          %{
            "meta_campos" => meta_campos_d,
            "data" => [ejemplo_renglon],
            "paginacion" => %{"pagina" => 1, "por_pagina" => 25, "total_filas" => 1, "total_paginas" => 1}
          }
          |> json_pretty()

        %{nombre: nombre, respuesta: respuesta}
      end)

    # "alta" (estado_origen_id: nil) NUNCA se llama vía POST .../transiciones/
    # :accion — ese endpoint busca la transición por el estado_id de un
    # registro que YA EXISTE (resolver_transicion/3 en MetaStateEngine), y
    # un registro recién creado nunca tiene estado_id: nil. "alta" corre
    # solo, automáticamente, DENTRO del POST /api/:tabla de siempre (ver
    # CatalogoGenerico.crear/2) — documentarla como si tuviera su propio
    # endpoint /:id/transiciones/alta describe un request que siempre
    # devuelve error, nunca funciona.
    {transiciones_alta, transiciones_normales} = Enum.split_with(assigns.transiciones, &is_nil(&1.estado_origen_id))
    transiciones_doc = Enum.map(transiciones_normales, &ejemplo_transicion(&1, assigns.campos, registro, estados_por_id, tabla, catalogos_detalle))

    respuesta_lista_mapa =
      %{"meta_campos" => meta_campos}
      |> agregar_si_no_vacio("meta_campos_detalle", meta_campos_detalle)
      |> Map.merge(%{
        "data" => [registro],
        "paginacion" => %{"pagina" => 1, "por_pagina" => 25, "total_filas" => 1, "total_paginas" => 1}
      })

    respuesta_uno_mapa =
      %{"meta_campos" => meta_campos}
      |> agregar_si_no_vacio("meta_campos_detalle", meta_campos_detalle)
      |> Map.put("data", registro)

    assigns =
      assigns
      |> assign(:tabla, tabla)
      |> assign(:tiene_estados, assigns.estados != [])
      |> assign(:tiene_transiciones, transiciones_normales != [])
      |> assign(:tiene_detalles, catalogos_detalle != [])
      |> assign(:catalogos_detalle, catalogos_detalle)
      |> assign(:renglones_detalle_doc, renglones_detalle_doc)
      |> assign(:transiciones_alta, transiciones_alta)
      |> assign(:transiciones_doc, transiciones_doc)
      |> assign(:ejemplo_wrap, "{\"#{tabla}\": {...}}")
      |> assign(:payload_crear, ejemplo_payload_con_renglones(assigns.campos, catalogos_detalle) |> json_pretty())
      |> assign(:respuesta_lista, respuesta_lista_mapa |> json_pretty())
      |> assign(:respuesta_uno, respuesta_uno_mapa |> json_pretty())
      |> assign(:respuesta_creado, %{"data" => registro} |> json_pretty())
      # Deliberadamente SIN "renglones" acá — el lote es sobre encabezados
      # (varios pedidos en un request), un concepto distinto de "cuántos
      # renglones tiene UN pedido" (ya mostrado arriba, en payload_crear).
      # Mezclar los dos en el mismo ejemplo es justo lo que generaba
      # confusión — el body real SÍ admite "renglones" por item si hace
      # falta, el texto de la tarjeta ya lo aclara sin mostrarlo acá.
      |> assign(:payload_crear_lote, %{tabla => [ejemplo_payload(assigns.campos), ejemplo_payload(assigns.campos)]} |> json_pretty())
      |> assign(:respuesta_creado_lote, %{"data" => [registro, Map.put(registro, "id", 2)]} |> json_pretty())
      |> assign(:respuesta_transiciones, ejemplo_transiciones_disponibles(assigns.transiciones) |> json_pretty())

    ~H"""
    <div class="space-y-4">
      <.tarjeta_endpoint metodo="GET" url={"/api/#{@tabla}?pagina=1&por_pagina=25"} descripcion="Listado paginado."
        respuesta_status="200 OK" respuesta={@respuesta_lista} />

      <.tarjeta_endpoint metodo="GET" url={"/api/#{@tabla}/:id"} descripcion="Un registro."
        respuesta_status="200 OK" respuesta={@respuesta_uno} />

      <.tarjeta_endpoint :for={d <- @renglones_detalle_doc} metodo="GET" url={"/api/#{d.nombre}?encabezado_id=:id"}
        descripcion={"Todos los renglones de #{@tabla} #:id. Filtro por query string — sirve con cualquier campo real del catálogo (ej. ?estado_id=... también funciona), no solo encabezado_id."}
        respuesta_status="200 OK" respuesta={d.respuesta} />

      <.tarjeta_endpoint metodo="POST" url={"/api/#{@tabla}"}
        descripcion={
          if @tiene_detalles,
            do: "Crea UN registro con TODOS sus renglones, en un solo request atómico. \"renglones\" es una lista por catálogo detalle — el ejemplo muestra 2 items, pero podés mandar los que necesites (10, 50, sin límite).",
            else: "Crea un registro nuevo."
        }
        body={@payload_crear} respuesta_status="201 Created" respuesta={@respuesta_creado} />

      <.tarjeta_endpoint metodo="POST" url={"/api/#{@tabla}"}
        descripcion={"Crea varios registros en un solo request (body = lista) — cada item puede traer su propia \"renglones\"."}
        body={@payload_crear_lote} respuesta_status="201 Created" respuesta={@respuesta_creado_lote} />

      <div :if={@transiciones_alta != []} class="bg-amber-50 border border-amber-200 text-amber-800 rounded-lg px-3 py-2">
        <p>
          <span :for={t <- @transiciones_alta} class="font-mono">"{t.accion}"</span>
          {if length(@transiciones_alta) == 1, do: "es la transición de alta", else: "son transiciones de alta"} de este
          catálogo (arranca cada registro nuevo en su estado inicial) — corre <strong>automáticamente</strong> dentro
          del <span class="font-mono">POST /api/{@tabla}</span> de arriba, con los campos del body de siempre. No
          existe <span class="font-mono">POST /:id/transiciones/{Enum.map_join(@transiciones_alta, "|", & &1.accion)}</span>
          como endpoint aparte — un registro recién creado nunca tiene <span class="font-mono">estado_id: nil</span>
          para que esa combinación resuelva.
        </p>
      </div>

      <.tarjeta_endpoint :if={@tiene_transiciones} metodo="GET" url={"/api/#{@tabla}/:id/transiciones"}
        descripcion="Transiciones disponibles desde el estado ACTUAL de ese registro puntual, con precondiciones ya evaluadas."
        respuesta_status="200 OK" respuesta={@respuesta_transiciones} />

      <.tarjeta_endpoint :for={t <- @transiciones_doc} metodo="POST" url={t.url} descripcion={t.descripcion}
        body={t.body} respuesta_status="200 OK" respuesta={t.respuesta} />

      <p :if={!@tiene_transiciones} class="text-gray-400">Este catálogo todavía no tiene transiciones definidas.</p>
    </div>
    """
  end

  # Ejemplo genérico (independiente de cualquier registro real) de lo que
  # devuelve GET .../transiciones — el real depende del estado en que esté
  # ESE registro puntual (evalúa precondiciones en vivo), acá solo se
  # ilustra la forma con las transiciones configuradas.
  defp ejemplo_transiciones_disponibles(transiciones) do
    %{"data" => Enum.map(transiciones, &%{"accion" => &1.accion, "etiqueta" => &1.etiqueta, "disponible" => true, "razones" => []})}
  end

  defp ejemplo_transicion(transicion, campos, registro, estados_por_id, tabla, catalogos_detalle) do
    origen = Map.get(estados_por_id, transicion.estado_origen_id, "— (alta)")
    destino = Map.get(estados_por_id, transicion.estado_destino_id, "?")

    {editables_header, editables_detalle} = separar_editables(transicion.campos_editables, campos, catalogos_detalle)

    payload_header =
      Map.new(editables_header, &{&1, valor_ejemplo_campo_por_nombre(campos, &1)})

    payload_renglones = ejemplo_renglones(catalogos_detalle, editables_detalle)

    body_mapa =
      if payload_renglones == %{}, do: payload_header, else: Map.put(payload_header, "renglones", payload_renglones)

    descripcion =
      cond do
        transicion.campos_editables == [] and catalogos_detalle == [] ->
          "\"#{transicion.accion}\": #{origen} → #{destino}. No acepta campos, solo cambia el estado."

        transicion.campos_editables == [] ->
          "\"#{transicion.accion}\": #{origen} → #{destino}. No acepta campos propios — opcionalmente puede mover renglones (ver \"renglones\" abajo)."

        true ->
          "\"#{transicion.accion}\": #{origen} → #{destino}. Campos editables en esta transición: #{Enum.join(transicion.campos_editables, ", ")}."
      end

    registro_tras_transicion =
      registro
      |> Map.put("estado_id", transicion.estado_destino_id)
      |> Map.put("estado_nombre", destino)
      |> Map.merge(payload_header)

    respuesta = %{"data" => registro_tras_transicion} |> json_pretty()

    %{
      url: "/api/#{tabla}/:id/transiciones/#{transicion.accion}",
      descripcion: descripcion,
      body: body_mapa |> json_pretty(),
      respuesta: respuesta
    }
  end

  # campos_editables es una lista plana (Fase 3, R4) que puede mezclar
  # campos del header con campos de cualquiera de sus catálogos detalle
  # (sin choque de nombres porque schema_context_field ya viene prefijado
  # por tabla) — separa por dueño real, no por prefijo de string, mismo
  # criterio que MetaEstadosAdmin.validar_campos_editables/1.
  defp separar_editables(campos_editables, campos_header, catalogos_detalle) do
    nombres_header = MapSet.new(campos_header, & &1.schema_context_field)
    {editables_header, resto} = Enum.split_with(campos_editables, &MapSet.member?(nombres_header, &1))

    editables_detalle =
      Enum.reduce(catalogos_detalle, %{}, fn %{schema_context_name: nombre, campos: campos_detalle}, acc ->
        nombres_detalle = MapSet.new(campos_detalle, & &1.schema_context_field)

        case Enum.filter(resto, &MapSet.member?(nombres_detalle, &1)) do
          [] -> acc
          encontrados -> Map.put(acc, nombre, encontrados)
        end
      end)

    {editables_header, editables_detalle}
  end

  # Un renglón de ejemplo por cada catálogo detalle del maestro — SIEMPRE
  # se documenta (con renglon_id solo) aunque esta transición puntual no
  # tenga campos editables para ese catálogo, porque mover renglones de
  # estado es válido igual (ver moduledoc de ejecutar_transicion/4).
  defp ejemplo_renglones(catalogos_detalle, editables_detalle) do
    Map.new(catalogos_detalle, fn %{schema_context_name: nombre, campos: campos_detalle} ->
      editables = Map.get(editables_detalle, nombre, [])

      item =
        editables
        |> Map.new(&{&1, valor_ejemplo_campo_por_nombre(campos_detalle, &1)})
        |> Map.put("renglon_id", 1)

      {nombre, [item]}
    end)
  end

  defp agregar_si_no_vacio(mapa, _llave, valor) when valor == %{}, do: mapa
  defp agregar_si_no_vacio(mapa, llave, valor), do: Map.put(mapa, llave, valor)

  defp valor_ejemplo_campo_por_nombre(campos, nombre) do
    case Enum.find(campos, &(&1.schema_context_field == nombre)) do
      nil -> "texto"
      campo -> valor_ejemplo_campo(campo.schema_context_properties)
    end
  end

  attr :metodo, :string, required: true
  attr :url, :string, required: true
  attr :descripcion, :string, default: nil
  attr :body, :string, default: nil
  attr :respuesta_status, :string, required: true
  attr :respuesta, :string, default: nil

  defp tarjeta_endpoint(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg overflow-hidden">
      <div class="px-3 py-2 border-b border-gray-200 flex items-center gap-2 bg-gray-50">
        <span class={[
          "px-2 py-0.5 rounded text-[11px] font-bold text-white shrink-0",
          @metodo == "GET" && "bg-blue-600",
          @metodo == "POST" && "bg-green-600",
          @metodo == "PATCH" && "bg-amber-600",
          @metodo == "DELETE" && "bg-red-600"
        ]}>{@metodo}</span>
        <span class="font-mono text-gray-700">{@url}</span>
      </div>
      <div class="p-3 space-y-2">
        <p :if={@descripcion} class="text-gray-500">{@descripcion}</p>
        <div :if={@body}>
          <p class="text-[11px] font-semibold uppercase tracking-wide text-gray-400 mb-1">Body</p>
          <pre class="bg-gray-50 border border-gray-200 rounded-lg p-2 overflow-x-auto font-mono text-[11px] text-gray-800">{@body}</pre>
        </div>
        <div>
          <p class="text-[11px] font-semibold uppercase tracking-wide text-gray-400 mb-1">Respuesta {@respuesta_status}</p>
          <pre :if={@respuesta} class="bg-gray-50 border border-gray-200 rounded-lg p-2 overflow-x-auto font-mono text-[11px] text-gray-800">{@respuesta}</pre>
        </div>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true

  defp modal_eliminar_campo(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div class="bg-white rounded-xl shadow-lg max-w-sm w-full p-4 text-xs">
        <h2 class="text-sm font-bold text-gray-900 mb-1">Eliminar campo</h2>
        <p class="text-gray-600 mb-1">
          Se eliminará <strong class="font-mono">{@form.campo}</strong> — la columna física se borra, esto no es reversible.
        </p>
        <%= if @form.filas_con_valor > 0 do %>
          <p class="text-red-600 font-semibold mb-3">
            {@form.filas_con_valor} fila(s) tienen datos en este campo — se pierden.
          </p>
        <% else %>
          <p class="text-gray-400 mb-3">Ninguna fila tiene datos en este campo todavía.</p>
        <% end %>

        <label class="block text-gray-700 mb-1">
          Escribe <strong class="font-mono">{@form.campo}</strong> para confirmar:
        </label>
        <input type="text" value={@form.confirmar_texto} phx-keyup="escribir_confirmacion_campo" autocomplete="off"
          placeholder={@form.campo}
          class="w-full border border-gray-300 rounded-lg px-2 py-1.5 mb-3 focus:outline-none focus:ring-2 focus:ring-red-500/40 focus:border-red-500" />

        <div class="flex justify-end gap-2">
          <button type="button" phx-click="cancelar_eliminar_campo" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
            Cancelar
          </button>
          <button type="button" phx-click="confirmar_eliminar_campo" disabled={@form.confirmar_texto != @form.campo}
            class="px-3 py-1.5 rounded-lg bg-red-600 text-white font-semibold hover:bg-red-700 disabled:opacity-40 disabled:cursor-not-allowed">
            Eliminar
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :local_label, :string, required: true

  # Qué campos del catálogo REFERENCIADO trae de prestado este campo tipo
  # "referencia" — lanzado desde el panel Relaciones. Presentado como 3
  # preguntas de negocio en columnas (no como una configuración de tablas):
  # 1) qué ves del catálogo relacionado, 2) qué le mandás vos de este, 3)
  # cómo se ve el registro al elegirlo/mostrarlo. El "stepper" de arriba es
  # solo decorativo/orientativo — las 3 columnas están siempre visibles
  # juntas, no hay paginado real (menos clics: nadie tiene que ir y volver
  # para comparar qué tildó en el paso 1 mientras decide el 2).
  defp modal_relacion(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-5xl w-full text-xs max-h-[92vh] flex flex-col overflow-hidden">
        <div class="px-5 pt-4 pb-3 border-b border-gray-100 flex items-start justify-between gap-3 flex-shrink-0">
          <div class="flex items-start gap-2.5">
            <span class="material-symbols-outlined text-purple-600 mt-0.5" style="font-size:20px">sync_alt</span>
            <div>
              <h2 class="text-sm font-bold text-gray-900">Configurar relación</h2>
              <p class="text-gray-500 mt-0.5">Define qué información se comparte entre este catálogo y <strong>{@form["catalogo_destino_label"]}</strong>.</p>
            </div>
          </div>
          <button type="button" phx-click="cerrar_form_relacion" class="text-gray-400 hover:text-gray-700 flex-shrink-0">
            <span class="material-symbols-outlined" style="font-size:20px">close</span>
          </button>
        </div>

        <div class="px-5 py-3 border-b border-gray-100 bg-gray-50/70 flex items-center gap-2 overflow-x-auto flex-shrink-0">
          <.paso_diagrama numero="1" titulo="Datos que verás" subtitulo={"De " <> @form["catalogo_destino_label"]} />
          <span class="flex-1 h-px bg-gray-200 min-w-[14px]"></span>
          <.paso_diagrama numero="2" titulo="Datos que envías" subtitulo={"A " <> @form["catalogo_destino_label"]} />
          <span class="flex-1 h-px bg-gray-200 min-w-[14px]"></span>
          <.paso_diagrama numero="3" titulo="Visualización" subtitulo="Cómo se muestra" />
        </div>

        <div :if={@form["error"]} class="mx-5 mt-3 bg-red-50 text-red-700 rounded-lg px-2.5 py-1.5 flex-shrink-0">{@form["error"]}</div>

        <%= if @form["campos_destino"] == [] do %>
          <div class="p-10 flex flex-col items-center gap-2 text-center">
            <span class="material-symbols-outlined text-amber-500" style="font-size:30px">warning</span>
            <p class="text-amber-700"><strong>{@form["catalogo_destino_label"]}</strong> todavía no tiene campos propios visibles.</p>
            <button type="button" phx-click="cerrar_form_relacion" class="mt-2 px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
              Cerrar
            </button>
          </div>
        <% else %>
          <form phx-change="previsualizar_visualizacion" phx-submit="guardar_relacion" id="form-relacion" phx-hook="RelacionCampos" class="flex-1 min-h-0 flex flex-col">
            <div class="flex-1 min-h-0 overflow-y-auto grid grid-cols-1 md:grid-cols-3 divide-y md:divide-y-0 md:divide-x divide-gray-100">
              <!-- ---------------- COLUMNA 1: qué ves del relacionado ---------------- -->
              <div class="p-4 flex flex-col gap-2.5 min-h-0" data-columna="1">
                <div>
                  <p class="font-bold text-gray-800">1. Datos que verás de {@form["catalogo_destino_label"]}</p>
                  <p class="text-gray-400 mt-0.5">Va a aparecer como columnas extra cada vez que este catálogo muestre el relacionado.</p>
                </div>

                <.toolbar_campos_relacion columna="1" placeholder={"Buscar en " <> @form["catalogo_destino_label"] <> "…"} />

                <div class="flex flex-col gap-3 overflow-y-auto pr-0.5" data-lista="1" style="max-height: 340px">
                  <.grupo_campos :for={{etiqueta_grupo, campos_grupo} <- agrupar_campos(@form["campos_destino"])} etiqueta={etiqueta_grupo}>
                    <.fila_campo :for={c <- campos_grupo} campo={c} name="campos[]" checked={c.schema_context_field in @form["seleccionados"]} />
                  </.grupo_campos>
                  <p class="hidden text-gray-400 text-center py-6" data-vacio="1">Ningún campo coincide con la búsqueda.</p>
                </div>
              </div>

              <!-- ---------------- COLUMNA 2: qué mandás vos ---------------- -->
              <div class="p-4 flex flex-col gap-2.5 min-h-0" data-columna="2">
                <div>
                  <p class="font-bold text-gray-800">2. Datos que envías a {@form["catalogo_destino_label"]}</p>
                  <p class="text-gray-400 mt-0.5">Va a aparecer en la pestaña "Relaciones" de <strong>{@form["catalogo_destino_label"]}</strong>, dentro de la tarjeta de <strong>{@local_label}</strong>.</p>
                </div>

                <%= if @form["campos_propios"] == [] do %>
                  <p class="text-gray-400">Este catálogo no tiene campos visibles todavía.</p>
                <% else %>
                  <.toolbar_campos_relacion columna="2" placeholder={"Buscar en " <> @local_label <> "…"} />

                  <div class="flex flex-col gap-3 overflow-y-auto pr-0.5" data-lista="2" style="max-height: 340px">
                    <.grupo_campos :for={{etiqueta_grupo, campos_grupo} <- agrupar_campos(@form["campos_propios"])} etiqueta={etiqueta_grupo}>
                      <.fila_campo :for={c <- campos_grupo} campo={c} name="campos_relacion[]" checked={c.schema_context_field in @form["seleccionados_propios"]} />
                    </.grupo_campos>
                    <p class="hidden text-gray-400 text-center py-6" data-vacio="2">Ningún campo coincide con la búsqueda.</p>
                  </div>

                  <p :if={@form["seleccionados_propios"] == []} class="text-gray-400">Sin nada tildado, se muestra la descripción de siempre + el id.</p>
                <% end %>
              </div>

              <!-- ---------------- COLUMNA 3: cómo se ve ---------------- -->
              <% cv = @form["campo_visualizacion"] %>
              <div class="p-4 flex flex-col gap-2.5 min-h-0" data-columna="3">
                <div>
                  <p class="font-bold text-gray-800">3. ¿Cómo se mostrará el registro?</p>
                  <p class="text-gray-400 mt-0.5">Define el texto que se ve al elegir o consultar {@form["catalogo_destino_label"]} desde acá.</p>
                </div>

                <div class="flex flex-col gap-1.5">
                  <.opcion_visualizacion valor="descripcion" cv={cv} titulo="Un solo dato" descripcion="Ej.: solo el nombre.">
                    <div :if={cv["modo"] == "descripcion"} class="mt-2">
                      <select name="campo_visualizacion[campo_descripcion]" class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
                        <option value="">— Elegir campo —</option>
                        <option :for={c <- @form["campos_destino"]} value={c.schema_context_field} selected={cv["campo_descripcion"] == c.schema_context_field}>
                          {c.schema_context_properties["etiqueta"] || c.schema_context_field}
                        </option>
                      </select>
                    </div>
                  </.opcion_visualizacion>

                  <.opcion_visualizacion valor="codigo_descripcion" cv={cv} titulo="Dos datos combinados" descripcion="Ej.: nombre + RFC, en el orden que quieras.">
                    <div :if={cv["modo"] == "codigo_descripcion"} class="mt-2 flex flex-col gap-1.5">
                      <select name="campo_visualizacion[campo_codigo]" class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
                        <option value="">— Primer dato —</option>
                        <option :for={c <- @form["campos_destino"]} value={c.schema_context_field} selected={cv["campo_codigo"] == c.schema_context_field}>
                          {c.schema_context_properties["etiqueta"] || c.schema_context_field}
                        </option>
                      </select>
                      <div class="flex items-center gap-1.5">
                        <button type="button" data-swap-visualizacion title="Invertir el orden"
                          class="flex-shrink-0 w-7 h-7 rounded-lg border border-gray-300 text-gray-500 hover:border-purple-400 hover:text-purple-700 flex items-center justify-center">
                          <span class="material-symbols-outlined" style="font-size:15px">swap_vert</span>
                        </button>
                        <select name="campo_visualizacion[campo_descripcion]" class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
                          <option value="">— Segundo dato —</option>
                          <option :for={c <- @form["campos_destino"]} value={c.schema_context_field} selected={cv["campo_descripcion"] == c.schema_context_field}>
                            {c.schema_context_properties["etiqueta"] || c.schema_context_field}
                          </option>
                        </select>
                      </div>
                    </div>
                  </.opcion_visualizacion>

                  <.opcion_visualizacion valor="plantilla" cv={cv} titulo="Personalizado" descripcion="Armalo vos combinando los datos que quieras.">
                    <div :if={cv["modo"] == "plantilla"} class="mt-2">
                      <input type="text" name="campo_visualizacion[plantilla]" value={cv["plantilla"]} placeholder="{campo_a} - {campo_b}"
                        class="w-full border border-gray-300 rounded-lg px-2 py-1.5 font-mono" />
                      <p class="text-gray-400 mt-1.5">Insertar dato:</p>
                      <div class="flex flex-wrap gap-1 mt-0.5">
                        <button :for={c <- @form["campos_destino"]} type="button" phx-click="insertar_variable_visualizacion"
                          phx-value-campo={c.schema_context_field} phx-value-destino="plantilla"
                          class="px-1.5 py-0.5 rounded bg-indigo-50 text-indigo-700 font-mono hover:bg-indigo-100">
                          +{"{" <> c.schema_context_field <> "}"}
                        </button>
                      </div>
                    </div>
                  </.opcion_visualizacion>

                  <details class="mt-0.5">
                    <summary class="cursor-pointer text-gray-400 hover:text-gray-600 select-none">Avanzado — fórmula condicional</summary>
                    <div class="mt-1.5 pl-0.5">
                      <label class="flex items-center gap-1.5 mb-1.5">
                        <input type="radio" name="campo_visualizacion[modo]" value="calculado" checked={cv["modo"] == "calculado"} class="accent-purple-600" />
                        <span class="text-gray-600">Usar una fórmula (ej. mostrar "Vencido" si aplica)</span>
                      </label>
                      <div :if={cv["modo"] == "calculado"}>
                        <input type="text" name="campo_visualizacion[formula]" value={cv["formula"]}
                          placeholder="IF {campo} > 0 THEN &quot;Sí&quot; ELSE &quot;No&quot;"
                          class="w-full border border-gray-300 rounded-lg px-2 py-1.5 font-mono" />
                        <p class="text-gray-400 mt-1.5">Insertar dato:</p>
                        <div class="flex flex-wrap gap-1 mt-0.5">
                          <button :for={c <- @form["campos_destino"]} type="button" phx-click="insertar_variable_visualizacion"
                            phx-value-campo={c.schema_context_field} phx-value-destino="formula"
                            class="px-1.5 py-0.5 rounded bg-indigo-50 text-indigo-700 font-mono hover:bg-indigo-100">
                            +{"{" <> c.schema_context_field <> "}"}
                          </button>
                        </div>
                      </div>
                    </div>
                  </details>
                </div>

                <div class="mt-1 border-t border-gray-100 pt-2.5">
                  <p class="text-gray-400 font-semibold uppercase tracking-wide mb-1.5" style="font-size:10px">Vista previa</p>
                  <div :if={@form["registro_muestra"]} class="flex items-center gap-2 bg-gray-50 border border-gray-200 rounded-lg px-2.5 py-2">
                    <span class="material-symbols-outlined text-purple-500 flex-shrink-0" style="font-size:16px">apartment</span>
                    <p class="font-semibold text-gray-900 truncate">{CatalogoGenerico.etiqueta_para_referencia(@form["registro_muestra"], %{"campo_visualizacion" => cv})}</p>
                  </div>
                  <p :if={!@form["registro_muestra"]} class="text-gray-400">
                    <strong>{@form["catalogo_destino_label"]}</strong> todavía no tiene registros para previsualizar.
                  </p>
                </div>
              </div>
            </div>

            <div class="flex justify-end gap-2 px-5 py-3 border-t border-gray-100 bg-gray-50/70 flex-shrink-0">
              <button type="button" phx-click="cerrar_form_relacion" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
                Cancelar
              </button>
              <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">
                Guardar relación
              </button>
            </div>
          </form>
        <% end %>
      </div>
    </div>
    """
  end

  attr :numero, :string, required: true
  attr :titulo, :string, required: true
  attr :subtitulo, :string, required: true

  # Paso del "stepper" decorativo de arriba del modal_relacion/1 — las 3
  # columnas están siempre visibles juntas (menos clics que un wizard
  # paginado real), esto es solo orientación visual de qué contesta cada
  # columna.
  defp paso_diagrama(assigns) do
    ~H"""
    <div class="flex items-center gap-2 flex-shrink-0">
      <span class="w-5 h-5 rounded-full bg-purple-600 text-white flex items-center justify-center font-bold flex-shrink-0" style="font-size:10px">{@numero}</span>
      <div class="leading-tight whitespace-nowrap">
        <p class="font-semibold text-gray-700" style="font-size:11px">{@titulo}</p>
        <p class="text-gray-400" style="font-size:10px">{@subtitulo}</p>
      </div>
    </div>
    """
  end

  attr :columna, :string, required: true
  attr :placeholder, :string, required: true

  # Buscador + "Todos"/"Limpiar" + contador de una columna de campos — el
  # hook JS RelacionCampos (assets/js/hooks/relacion_campos.js) es el
  # dueño real de este comportamiento (filtra, tilda, cuenta), todo del
  # lado del cliente: los checkboxes de esta columna nunca tuvieron
  # phx-change por campo (solo se leen al Guardar), así que no hay razón
  # para ida y vuelta al servidor por tipear en el buscador o tildar
  # "Todos".
  defp toolbar_campos_relacion(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <div class="flex items-center gap-1.5">
        <label class="flex-1 flex items-center gap-1.5 border border-gray-300 rounded-lg px-2 py-1.5 text-gray-400 focus-within:border-purple-400">
          <span class="material-symbols-outlined" style="font-size:14px">search</span>
          <input type="text" data-buscador={@columna} placeholder={@placeholder}
            class="border-none outline-none text-gray-700 w-full bg-transparent" />
        </label>
        <button type="button" data-todos={@columna} class="text-purple-700 font-semibold hover:text-purple-900 whitespace-nowrap flex-shrink-0">Todos</button>
        <button type="button" data-limpiar={@columna} class="text-gray-400 font-semibold hover:text-gray-600 whitespace-nowrap flex-shrink-0">Limpiar</button>
      </div>
      <p class="text-gray-400" data-contador={@columna}></p>
    </div>
    """
  end

  attr :etiqueta, :string, default: nil
  slot :inner_block, required: true

  defp grupo_campos(assigns) do
    ~H"""
    <div data-grupo>
      <button :if={@etiqueta} type="button" data-grupo-toggle
        class="w-full flex items-center justify-between text-gray-400 font-bold uppercase tracking-wide mb-1.5 hover:text-gray-600" style="font-size:10px">
        <span>{@etiqueta}</span>
        <span class="material-symbols-outlined" style="font-size:15px" data-grupo-icono>expand_more</span>
      </button>
      <div class="flex flex-col gap-1" data-grupo-body>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :campo, :map, required: true
  attr :name, :string, required: true
  attr :checked, :boolean, required: true

  defp fila_campo(assigns) do
    props = assigns.campo.schema_context_properties
    etiqueta = props["etiqueta"] || assigns.campo.schema_context_field

    assigns =
      assigns
      |> assign(:etiqueta, etiqueta)
      |> assign(:icono, icono_campo(assigns.campo))
      |> assign(:buscable, String.downcase(etiqueta <> " " <> assigns.campo.schema_context_field))

    ~H"""
    <label class="flex items-center gap-2 rounded-lg border border-transparent hover:bg-gray-50 px-1.5 py-1 cursor-pointer" data-fila data-buscable={@buscable}>
      <input type="checkbox" name={@name} value={@campo.schema_context_field} checked={@checked} class="accent-purple-600 rounded flex-shrink-0" data-fila-input />
      <span class="material-symbols-outlined text-gray-400 flex-shrink-0" style="font-size:15px">{@icono}</span>
      <span class="flex-1 min-w-0">
        <span class="block text-gray-800 font-medium truncate">{@etiqueta}</span>
        <span class="block text-gray-400 font-mono truncate" style="font-size:10px">{@campo.schema_context_field}</span>
      </span>
    </label>
    """
  end

  attr :valor, :string, required: true
  attr :cv, :map, required: true
  attr :titulo, :string, required: true
  attr :descripcion, :string, required: true
  slot :inner_block, required: true

  # Tarjeta de radio de la columna 3 (modo de campo_visualizacion) — clic
  # en cualquier parte de la tarjeta selecciona el radio (comportamiento
  # nativo de <label>); los controles anidados en el slot (selects,
  # input, botones +variable) siguen funcionando normal, un <label> nunca
  # les roba el clic a sus propios hijos interactivos.
  defp opcion_visualizacion(assigns) do
    ~H"""
    <label class={[
      "flex flex-col gap-0.5 border rounded-lg px-2.5 py-2 cursor-pointer transition-colors",
      if(@cv["modo"] == @valor, do: "border-purple-400 bg-purple-50", else: "border-gray-200 hover:border-gray-300")
    ]}>
      <div class="flex items-center gap-2">
        <input type="radio" name="campo_visualizacion[modo]" value={@valor} checked={@cv["modo"] == @valor} class="accent-purple-600" />
        <span class="font-semibold text-gray-800">{@titulo}</span>
      </div>
      <span class="text-gray-400 pl-5">{@descripcion}</span>
      {render_slot(@inner_block)}
    </label>
    """
  end

  attr :form, :map, required: true

  # "Dependencia o filtro en cascada" de un campo referencia (combos en
  # cascada, ver MetaSchemaContext.resolver_filtros/3 y
  # validar_sin_ciclo/3) — lanzado desde el botón "Cascada" del panel
  # "Relaciones". Genérico: "campo_padre" siempre es OTRO campo
  # "referencia" YA CREADO en este mismo catálogo (nunca un nombre fijo
  # como "estado_id"), "campo_remoto" siempre una columna real del
  # catálogo DESTINO de `campo` — Estado/Municipio/Localidad es apenas un
  # caso posible entre muchos (Empresa→Sucursal→Almacén, Marca→Modelo,
  # etc.), no hay nada acá que lo asuma.
  defp modal_dependencia(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-lg w-full text-xs max-h-[90vh] overflow-y-auto">
        <div class="px-4 pt-4 pb-3 border-b border-gray-100 flex items-start justify-between gap-3">
          <div class="flex items-start gap-2.5">
            <span class="material-symbols-outlined text-purple-600 mt-0.5" style="font-size:20px">stacked_line_chart</span>
            <div>
              <h2 class="text-sm font-bold text-gray-900">Dependencia o filtro en cascada</h2>
              <p class="text-gray-500 mt-0.5">
                De qué otro campo depende <strong class="font-mono">{@form["campo"]}</strong> para acotar sus opciones — ej.
                Municipio solo trae los que pertenecen al Estado ya elegido.
              </p>
            </div>
          </div>
          <button type="button" phx-click="cerrar_form_dependencia" class="text-gray-400 hover:text-gray-700 flex-shrink-0">
            <span class="material-symbols-outlined" style="font-size:20px">close</span>
          </button>
        </div>

        <div class="p-4">
          <div :if={@form["error"]} class="bg-red-50 text-red-700 rounded-lg px-2.5 py-1.5 mb-3">{@form["error"]}</div>

          <%= if @form["otros_referencia"] == [] do %>
            <p class="text-gray-400 mb-3">
              Este catálogo no tiene otro campo tipo <span class="font-mono">referencia</span> (que no dependa ya de
              <strong class="font-mono">{@form["campo"]}</strong>) del que pueda depender todavía.
            </p>
            <div class="flex justify-end">
              <button type="button" phx-click="cerrar_form_dependencia" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
                Cerrar
              </button>
            </div>
          <% else %>
            <form phx-change="dependencia_cambiar" phx-submit="guardar_dependencia">
              <%= if @form["dependencias"] == [] do %>
                <p class="text-gray-400 mb-3">
                  <strong class="font-mono">{@form["campo"]}</strong> no depende de nada todavía — siempre trae
                  <strong>{@form["catalogo_destino_label"]}</strong> entero.
                </p>
              <% else %>
                <div class="flex flex-col gap-2 mb-3">
                  <%= for {dep, i} <- Enum.with_index(@form["dependencias"]) do %>
                    <div class="border border-gray-200 rounded-lg p-2.5">
                      <div class="flex items-center justify-between mb-1.5">
                        <span class="text-gray-500 font-semibold">Depende de</span>
                        <button type="button" phx-click="dependencia_quitar" phx-value-indice={i} class="text-red-600 hover:text-red-800 font-semibold">
                          Quitar
                        </button>
                      </div>
                      <div class="grid grid-cols-2 gap-2">
                        <div>
                          <label class="block text-gray-500 mb-0.5">Campo padre</label>
                          <select name={"dependencias[#{i}][campo_padre]"} class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
                            <option value="">— Elegir —</option>
                            <option :for={c <- @form["otros_referencia"]} value={c.schema_context_field} selected={dep["campo_padre"] == c.schema_context_field}>
                              {c.schema_context_properties["etiqueta"] || c.schema_context_field}
                            </option>
                          </select>
                        </div>
                        <div>
                          <label class="block text-gray-500 mb-0.5">Filtrar {@form["catalogo_destino_label"]} por</label>
                          <select name={"dependencias[#{i}][campo_remoto]"} class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
                            <option value="">— Elegir —</option>
                            <option :for={c <- @form["campos_destino"]} value={c.schema_context_field} selected={dep["campo_remoto"] == c.schema_context_field}>
                              {c.schema_context_properties["etiqueta"] || c.schema_context_field}
                            </option>
                          </select>
                        </div>
                      </div>
                      <label class="flex items-center gap-1.5 mt-1.5">
                        <input type="hidden" name={"dependencias[#{i}][obligatorio]"} value="false" />
                        <input type="checkbox" name={"dependencias[#{i}][obligatorio]"} value="true" checked={dep["obligatorio"] != false} class="accent-purple-600" />
                        <span class="text-gray-600">Obligatorio — deshabilitar {@form["campo"]} hasta elegir esto</span>
                      </label>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <button type="button" phx-click="dependencia_agregar" class="text-purple-700 hover:text-purple-900 font-semibold mb-3">
                + Agregar dependencia
              </button>

              <div :if={@form["descendientes"] != []} class="bg-gray-50 border border-gray-200 rounded-lg px-2.5 py-1.5 mb-3">
                <p class="text-gray-500">Campos que ya dependen de <strong class="font-mono">{@form["campo"]}</strong> (se limpian solos si este cambia):</p>
                <p class="font-semibold text-gray-800">{Enum.join(@form["descendientes"], " → ")}</p>
              </div>

              <div class="flex justify-end gap-2">
                <button type="button" phx-click="cerrar_form_dependencia" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
                  Cancelar
                </button>
                <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">
                  Guardar
                </button>
              </div>
            </form>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @presets_formato_string [
    {"telefono", "Teléfono"},
    {"cp", "Código postal"},
    {"rfc", "RFC"},
    {"curp", "CURP"},
    {"fecha", "Fecha libre"},
    {"personalizada", "Personalizada"},
    {"numero", "Número"},
    {"moneda", "Moneda"}
  ]
  @presets_formato_numerico [{"numero", "Número"}, {"moneda", "Moneda"}]

  attr :form, :map, required: true

  # Panel único (no el wizard de 4 pasos del mockup de referencia — ver
  # modal_dependencia/1 arriba, mismo criterio de "versión condensada para
  # LiveView server-rendered"): qué se ofrece depende del `tipo` real del
  # campo, nunca un <select> de "tipo de formato" genérico que mezcle
  # texto y número.
  defp modal_formato_captura(assigns) do
    assigns =
      assign(assigns, :presets, if(assigns.form["tipo"] == "string", do: @presets_formato_string, else: @presets_formato_numerico))

    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-md w-full text-xs max-h-[90vh] overflow-y-auto">
        <div class="px-4 pt-4 pb-3 border-b border-gray-100 flex items-start justify-between gap-3">
          <div class="flex items-start gap-2.5">
            <span class="material-symbols-outlined text-purple-600 mt-0.5" style="font-size:20px">dialpad</span>
            <div>
              <h2 class="text-sm font-bold text-gray-900">Formato de captura</h2>
              <p class="text-gray-500 mt-0.5">
                Cómo se escribe y se guarda <strong class="font-mono">{@form["campo"]}</strong>.
              </p>
            </div>
          </div>
          <button type="button" phx-click="cerrar_form_formato" class="text-gray-400 hover:text-gray-700 flex-shrink-0">
            <span class="material-symbols-outlined" style="font-size:20px">close</span>
          </button>
        </div>

        <div class="p-4">
          <div :if={@form["error"]} class="bg-red-50 text-red-700 rounded-lg px-2.5 py-1.5 mb-3">{@form["error"]}</div>

          <form phx-change="formato_cambiar" phx-submit="guardar_formato" class="flex flex-col gap-3">
            <label class="flex items-center gap-1.5">
              <input type="hidden" name="habilitada" value="false" />
              <input type="checkbox" name="habilitada" value="true" checked={@form["habilitada"]} class="accent-purple-600" />
              <span class="text-gray-700 font-semibold">Habilitar formato de captura</span>
            </label>

            <%= if @form["habilitada"] do %>
              <div>
                <p class="text-gray-500 mb-1 font-semibold">Formato</p>
                <div class="grid grid-cols-2 gap-1.5">
                  <label :for={{valor, etiqueta} <- @presets} class={[
                    "flex items-center gap-1.5 border rounded-lg px-2 py-1.5 cursor-pointer",
                    @form["modo"] == valor && "border-purple-500 bg-purple-50" || "border-gray-200"
                  ]}>
                    <input type="radio" name="modo" value={valor} checked={@form["modo"] == valor} class="accent-purple-600" />
                    {etiqueta}
                  </label>
                </div>
              </div>

              <%= if @form["modo"] in ["numero", "moneda"] do %>
                <div class="grid grid-cols-2 gap-2">
                  <div>
                    <label class="block text-gray-500 mb-0.5 font-semibold">Decimales</label>
                    <input type="number" name="decimales" value={@form["decimales"]} min="0" max="6"
                      class="w-full border border-gray-300 rounded-lg px-2 py-1.5" />
                  </div>
                  <div :if={@form["modo"] == "moneda"}>
                    <label class="block text-gray-500 mb-0.5 font-semibold">Símbolo</label>
                    <div class="flex gap-1">
                      <input type="text" name="simbolo" value={@form["simbolo"]} maxlength="4" class="w-14 border border-gray-300 rounded-lg px-2 py-1.5" />
                      <select name="simbolo_posicion" class="flex-1 border border-gray-300 rounded-lg px-1.5 py-1.5">
                        <option value="prefijo" selected={@form["simbolo_posicion"] == "prefijo"}>Antes</option>
                        <option value="sufijo" selected={@form["simbolo_posicion"] == "sufijo"}>Después</option>
                      </select>
                    </div>
                  </div>
                </div>
                <label class="flex items-center gap-1.5">
                  <input type="hidden" name="separador_miles" value="false" />
                  <input type="checkbox" name="separador_miles" value="true" checked={@form["separador_miles"]} class="accent-purple-600" />
                  Separador de miles
                </label>
                <label class="flex items-center gap-1.5">
                  <input type="hidden" name="permitir_negativos" value="false" />
                  <input type="checkbox" name="permitir_negativos" value="true" checked={@form["permitir_negativos"]} class="accent-purple-600" />
                  Permitir negativos
                </label>

                <%= if @form["tipo"] == "string" do %>
                  <div>
                    <p class="text-gray-500 mb-1 font-semibold">Guardar valor como</p>
                    <div class="grid grid-cols-2 gap-1.5">
                      <label class={["flex flex-col gap-0.5 border rounded-lg px-2 py-1.5 cursor-pointer", @form["guardar_formato"] != true && "border-purple-500 bg-purple-50" || "border-gray-200"]}>
                        <span class="flex items-center gap-1.5"><input type="radio" name="guardar_formato" value="false" checked={@form["guardar_formato"] != true} class="accent-purple-600" /> Solo datos</span>
                        <span class="font-mono text-gray-500">{formato_ejemplo(@form, false)}</span>
                      </label>
                      <label class={["flex flex-col gap-0.5 border rounded-lg px-2 py-1.5 cursor-pointer", @form["guardar_formato"] == true && "border-purple-500 bg-purple-50" || "border-gray-200"]}>
                        <span class="flex items-center gap-1.5"><input type="radio" name="guardar_formato" value="true" checked={@form["guardar_formato"] == true} class="accent-purple-600" /> Con formato</span>
                        <span class="font-mono text-gray-500">{formato_ejemplo(@form, true)}</span>
                      </label>
                    </div>
                  </div>
                <% else %>
                  <p class="text-gray-500">Ejemplo: <span class="font-mono text-gray-700">{formato_ejemplo(@form, true)}</span></p>
                <% end %>
              <% else %>
                <div>
                  <label class="block text-gray-500 mb-0.5 font-semibold">Patrón</label>
                  <input type="text" name="patron" value={@form["patron"]} readonly={@form["modo"] != "personalizada"}
                    placeholder="(999) 999-9999" spellcheck="false"
                    class="w-full border border-gray-300 rounded-lg px-2 py-1.5 font-mono read-only:bg-gray-50 read-only:text-gray-500" />
                  <p class="mt-0.5 text-gray-500"><b class="font-mono">A</b> letra · <b class="font-mono">9</b> número · <b class="font-mono">*</b> cualquiera — el resto se inserta solo.</p>
                  <p :if={@form["modo"] == "fecha"} class="mt-0.5 text-gray-500">También suma un ícono de calendario junto al campo para elegir la fecha en vez de tipearla.</p>
                </div>

                <div>
                  <p class="text-gray-500 mb-1 font-semibold">Guardar valor como</p>
                  <div class="grid grid-cols-2 gap-1.5">
                    <label class={["flex flex-col gap-0.5 border rounded-lg px-2 py-1.5 cursor-pointer", @form["guardar_formato"] != true && "border-purple-500 bg-purple-50" || "border-gray-200"]}>
                      <span class="flex items-center gap-1.5"><input type="radio" name="guardar_formato" value="false" checked={@form["guardar_formato"] != true} class="accent-purple-600" /> Solo datos</span>
                      <span class="font-mono text-gray-500">{formato_ejemplo(@form, false)}</span>
                    </label>
                    <label class={["flex flex-col gap-0.5 border rounded-lg px-2 py-1.5 cursor-pointer", @form["guardar_formato"] == true && "border-purple-500 bg-purple-50" || "border-gray-200"]}>
                      <span class="flex items-center gap-1.5"><input type="radio" name="guardar_formato" value="true" checked={@form["guardar_formato"] == true} class="accent-purple-600" /> Con formato</span>
                      <span class="font-mono text-gray-500">{formato_ejemplo(@form, true)}</span>
                    </label>
                  </div>
                </div>
              <% end %>

              <div class="border-t border-gray-100 pt-2.5 flex flex-col gap-2">
                <label class="flex items-center gap-1.5">
                  <input type="hidden" name="estricto" value="false" />
                  <input type="checkbox" name="estricto" value="true" checked={@form["estricto"]} class="accent-purple-600" />
                  <%= if @form["modo"] in ["numero", "moneda"] do %>
                    No deja tipear letras ni más decimales de los configurados
                  <% else %>
                    Máscara estricta — no deja tipear un carácter que no calza
                  <% end %>
                </label>
                <label class="flex items-center gap-1.5">
                  <input type="hidden" name="permitir_incompleto" value="false" />
                  <input type="checkbox" name="permitir_incompleto" value="true" checked={@form["permitir_incompleto"]} class="accent-purple-600" />
                  Permitir guardar un valor incompleto
                </label>
                <div :if={!@form["permitir_incompleto"]}>
                  <label class="block text-gray-500 mb-0.5">Mensaje si el valor no es válido</label>
                  <input type="text" name="mensaje_invalido" value={@form["mensaje_invalido"]}
                    class="w-full border border-gray-300 rounded-lg px-2 py-1.5" />
                </div>
              </div>
            <% end %>

            <div class="flex justify-end gap-2 pt-1">
              <button type="button" phx-click="cerrar_form_formato" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
                Cancelar
              </button>
              <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">
                Guardar
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # Línea de ejemplo estática (server-side — LiveView ya re-renderiza en
  # cada phx-change, no hace falta JS de preview acá como en el mockup de
  # referencia). `con_formato?` distingue las dos columnas de "Guardar
  # valor como" — irrelevante para número/moneda en un campo integer/
  # decimal real (la BD siempre guarda el número crudo, se llama con
  # `true` ahí para la línea "Ejemplo:"), pero SÍ importa cuando número/
  # moneda vive en un campo string (separadores/símbolo solo aparecen si
  # se decide persistir "con formato").
  defp formato_ejemplo(%{"modo" => modo} = form, con_formato?) when modo in ["numero", "moneda"] do
    decimales = form["decimales"] || 0
    entero_agrupado = if con_formato?, do: agrupar_miles("1234567", form["separador_miles"]), else: "1234567"
    numero = if decimales > 0, do: "#{entero_agrupado}.#{String.duplicate("5", decimales)}", else: entero_agrupado

    if con_formato? and modo == "moneda" and form["simbolo"] not in [nil, ""] do
      if form["simbolo_posicion"] == "sufijo", do: "#{numero} #{form["simbolo"]}", else: "#{form["simbolo"]}#{numero}"
    else
      numero
    end
  end

  defp formato_ejemplo(%{"tipo" => "string", "modo" => modo} = form, con_formato?) do
    patron = patron_por_defecto(modo) || form["patron"] || ""

    cruda =
      patron
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.map(fn
        {"A", i} -> Enum.at(~w(A B C D E F G H J), rem(i, 9))
        {"9", i} -> Integer.to_string(rem(i, 10))
        {"*", _i} -> "X"
        {c, _i} -> c
      end)
      |> Enum.join()

    if con_formato?, do: cruda, else: patron |> String.graphemes() |> Enum.zip(String.graphemes(cruda)) |> Enum.filter(fn {p, _c} -> p in ["A", "9", "*"] end) |> Enum.map(&elem(&1, 1)) |> Enum.join()
  end

  defp agrupar_miles(entero, true) do
    entero
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp agrupar_miles(entero, _separador_miles), do: entero

  defp modal_estado(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div class="bg-white rounded-xl shadow-lg max-w-sm w-full p-4 text-xs">
        <h2 class="text-sm font-bold text-gray-900 mb-3">{if @form["id"], do: "Editar estado", else: "Agregar estado"}</h2>

        <%= if @form["error"] do %>
          <div class="bg-red-50 text-red-700 rounded-lg px-2 py-1.5 mb-2">{@form["error"]}</div>
        <% end %>

        <form phx-submit="guardar_estado" class="space-y-2">
          <input type="hidden" name="registro_id" value={@form["id"]} />
          <div>
            <label class="block text-gray-700 mb-0.5">Nombre</label>
            <input type="text" name="nombre" value={@form["nombre"]} placeholder="Prospecto" required maxlength="100"
              class="w-full border border-gray-300 rounded-lg px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />
          </div>

          <div class="grid grid-cols-2 gap-2">
            <div>
              <label class="block text-gray-700 mb-0.5">Orden</label>
              <input type="number" name="orden" value={@form["orden"]} required
                class="w-full border border-gray-300 rounded-lg px-2 py-1.5" />
            </div>
            <div>
              <label class="block text-gray-700 mb-0.5">Color</label>
              <input type="color" name="color" value={@form["color"]} class="w-full h-[30px] border border-gray-300 rounded-lg px-1 py-0.5" />
            </div>
          </div>

          <%= if @form["es_inicial_forzado"] do %>
            <div class="flex items-center gap-1.5 text-gray-600">
              <input type="hidden" name="es_inicial" value="true" />
              <span class="material-symbols-outlined text-purple-600" style="font-size: 16px">check_circle</span>
              Va a ser el estado inicial — es el primer estado del catálogo, no se puede desmarcar.
            </div>
          <% else %>
            <label class="flex items-center gap-1.5">
              <input type="hidden" name="es_inicial" value="false" />
              <input type="checkbox" name="es_inicial" value="true" checked={@form["es_inicial"] == true} class="accent-purple-600" />
              Es el estado inicial
            </label>
          <% end %>

          <div class="flex justify-end gap-2 pt-2">
            <button type="button" phx-click="cerrar_form_estado" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
              Cancelar
            </button>
            <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">
              Guardar
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :estados, :list, required: true
  attr :campos, :list, required: true
  attr :catalogos_detalle, :list, default: []

  defp modal_transicion(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div class="bg-white rounded-xl shadow-lg max-w-lg w-full max-h-[90vh] overflow-y-auto p-4 text-xs">
        <h2 class="text-sm font-bold text-gray-900 mb-3">{if @form["id"], do: "Editar transición", else: "Agregar transición"}</h2>

        <%= if @form["error"] do %>
          <div class="bg-red-50 text-red-700 rounded-lg px-2 py-1.5 mb-2">{@form["error"]}</div>
        <% end %>

        <%!-- Todo el modal organizado en tabs desde arriba (2026-08-04, a
             pedido explícito): antes "Acción/Etiqueta/Permisos/Origen-
             Destino" quedaban sueltos arriba y solo "Campos editables"
             tenía sus propios tabs (Encabezado + uno por catálogo detalle)
             más abajo — con catálogos de 10+ campos, esa mezcla de form
             largo + mini-tabs quedaba difícil de escanear. Ahora es un
             solo nivel de tabs para todo el modal: "Acción" (los datos de
             siempre) + "Encabezado" + uno por detalle. Mismo mecanismo de
             siempre (tabs_motor 100% cliente/JS) — el <form> sigue siendo
             UNO solo por fuera de los tabs, así que ningún input pierde su
             valor al cambiar de tab (solo se esconde con display:none). --%>
        <.tabs_motor id="campos-editables" tabs={
          [%{key: "accion", label: "Acción"}, %{key: "header", label: "Encabezado"}] ++
            Enum.map(@catalogos_detalle, &%{key: &1.nombre, label: &1.etiqueta})
        } />

        <form phx-submit="guardar_transicion" class="space-y-2">
          <input type="hidden" name="registro_id" value={@form["id"]} />

          <div id="campos-editables-panel-accion" class="space-y-2">
            <div>
              <label class="block text-gray-700 mb-0.5">Acción</label>
              <input type="text" name="accion" value={@form["accion"]} placeholder="activar" required maxlength="100"
                class="w-full border border-gray-300 rounded-lg px-2 py-1.5 font-mono focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />
              <p class="mt-0.5 text-[11px] text-gray-500">
                Se guarda en minúsculas. <span class="font-mono">guardar</span> como self-loop (mismo origen y destino) es la única forma de habilitar PATCH directo por API — cualquier otro nombre no lo activa.
              </p>
            </div>
            <div>
              <label class="block text-gray-700 mb-0.5">Etiqueta</label>
              <input type="text" name="etiqueta" value={@form["etiqueta"]} placeholder="Activar" required maxlength="100"
                class="w-full border border-gray-300 rounded-lg px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />
            </div>

            <%!-- Solo tiene sentido para una transición ya guardada (cada fila
                 de permiso se registra por {recurso, accion} — antes de
                 guardar no hay accion definitiva todavía). Sin la fila del
                 ENCABEZADO nadie ve/ejecuta la transición ahí; sin la fila de
                 un catálogo DETALLE, nadie puede mover renglones de esa tabla
                 en esta transición — ni el administrador (no es un comodín,
                 ver Permissions.can?/3), ambos casos encontrados reales con
                 pty_crac_clientes. Conceder a roles puntuales sigue siendo en
                 Roles/Permission Sets, esto solo asegura que la fila exista. --%>
            <div :if={@form["id"]} class="rounded-lg border border-gray-200 divide-y divide-gray-100">
              <div :for={p <- @form["permisos"]} class="px-2 py-1.5 flex items-center justify-between gap-2">
                <span class={["font-semibold", if(p.existe, do: "text-green-700", else: "text-amber-700")]}>
                  <%= if p.existe do %>
                    ✓ {p.etiqueta}
                  <% else %>
                    ⚠ {p.etiqueta} — sin permiso registrado
                  <% end %>
                </span>
                <button :if={!p.existe} type="button" phx-click="registrar_permiso_transicion" phx-value-recurso={p.recurso}
                  class="px-2 py-1 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 whitespace-nowrap">
                  Registrar permiso
                </button>
              </div>
            </div>

            <div class="grid grid-cols-2 gap-2">
              <div>
                <label class="block text-gray-700 mb-0.5">Origen</label>
                <select name="estado_origen_id" class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
                  <option value="">— (alta, sin origen) —</option>
                  <%= for e <- @estados do %>
                    <option value={e.id} selected={@form["estado_origen_id"] == to_string(e.id)}>{e.nombre}</option>
                  <% end %>
                </select>
              </div>
              <div>
                <label class="block text-gray-700 mb-0.5">Destino</label>
                <select name="estado_destino_id" required class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
                  <option value="">— Elegir —</option>
                  <%= for e <- @estados do %>
                    <option value={e.id} selected={@form["estado_destino_id"] == to_string(e.id)}>{e.nombre}</option>
                  <% end %>
                </select>
              </div>
            </div>
          </div>

          <%!-- Catálogo Maestro-Detalle (R4): un campo de un catálogo detalle
               es tan "editable en esta transición" como uno del propio
               maestro (el motor ya lo acepta desde Fase 3). Con 1 maestro +
               N detalles de hasta 20-30 campos, listar todo suelto es
               inmanejable — cada uno es su propio tab (arriba, junto con
               "Acción") + buscador por tab + "Todos/Ninguno". Un solo
               <input name="campos_editables[]"> compartido entre TODOS los
               tabs (siguen en el DOM aunque el tab esté oculto, solo con
               display:none) — el submit junta la selección real sin
               importar en qué tab haya quedado parado el usuario. --%>
          <div id="campos-editables-panel-header" class="hidden">
            <label class="block text-gray-700 mb-1">Campos editables en esta transición</label>
            <.grupo_campos_editables grupo="header" campos={@campos} form={@form} />
          </div>
          <%= for cat <- @catalogos_detalle do %>
            <div id={"campos-editables-panel-#{cat.nombre}"} class="hidden">
              <label class="block text-gray-700 mb-1">Campos editables en esta transición</label>
              <.grupo_campos_editables grupo={cat.nombre} campos={cat.campos} form={@form} />
            </div>
          <% end %>

          <div class="flex justify-end gap-2 pt-2">
            <button type="button" phx-click="cerrar_form_transicion" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
              Cancelar
            </button>
            <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">
              Guardar
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # Un grupo (header o un catálogo detalle) del selector de campos
  # editables — buscador propio + "Todos/Ninguno" + grilla de 2 columnas
  # (menos alto que una fila por checkbox, mismo criterio que el selector
  # de íconos). `campos_editables[]` es el mismo input en todos los
  # grupos — la selección real vive en @form, no en qué tab está visible.
  attr :grupo, :string, required: true
  attr :campos, :list, required: true
  attr :form, :map, required: true

  defp grupo_campos_editables(assigns) do
    busqueda = get_in(assigns.form, ["busqueda_campos", assigns.grupo]) || ""
    seleccionados = assigns.form["campos_editables"] || []

    visibles =
      if busqueda == "" do
        assigns.campos
      else
        texto = String.downcase(busqueda)
        Enum.filter(assigns.campos, &String.contains?(String.downcase(&1.schema_context_field), texto))
      end

    assigns =
      assigns
      |> assign(:busqueda, busqueda)
      |> assign(:seleccionados, seleccionados)
      |> assign(:visibles, visibles)

    ~H"""
    <div class="space-y-1.5">
      <div class="flex items-center gap-1">
        <input type="text" value={@busqueda} phx-keyup="buscar_campo_transicion" phx-value-grupo={@grupo} phx-debounce="200"
          placeholder="Buscar campo..."
          class="flex-1 border border-gray-300 rounded-lg px-2 py-1 text-[11px] focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />
        <button type="button" phx-click="marcar_todos_campos" phx-value-grupo={@grupo}
          class="text-purple-700 font-semibold hover:underline whitespace-nowrap">Todos</button>
        <button type="button" phx-click="desmarcar_todos_campos" phx-value-grupo={@grupo}
          class="text-gray-500 font-semibold hover:underline whitespace-nowrap">Ninguno</button>
      </div>
      <div class="flex flex-col gap-y-1 max-h-48 overflow-y-auto border border-gray-200 rounded-lg p-1.5">
        <%= for c <- @visibles do %>
          <label class="flex items-center gap-1 min-w-0">
            <input type="checkbox" name="campos_editables[]" value={c.schema_context_field}
              checked={c.schema_context_field in @seleccionados} class="accent-purple-600 shrink-0" />
            <span class="font-mono" title={c.schema_context_field}>{c.schema_context_field}</span>
          </label>
        <% end %>
        <%= if @visibles == [] do %>
          <p class="text-gray-400 text-center py-2">Sin resultados.</p>
        <% end %>
      </div>
    </div>
    """
  end
end
