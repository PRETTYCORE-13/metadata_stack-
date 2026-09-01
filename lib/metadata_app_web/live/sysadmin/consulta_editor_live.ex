defmodule MetadataAppWeb.Sysadmin.ConsultaEditorLive do
  # Admin de una Consulta Ecto (schema_context_type: 3) — mismo espíritu
  # que BcMotorLive (tabs), pero mucho más chico: una Consulta no tiene
  # campos propios editables (tipo/longitud/default/obligatorio vienen
  # SIEMPRE del catálogo origen, de solo lectura acá), no tiene estados,
  # no tiene TRN, no transacciona nunca. Ver MetadataApp.MetaConsultas
  # para el motor real (arma la query, filtra, pagina, totaliza).
  #
  # 5 tabs (2026-08-26), mismo orden que BcMotorLive (Configuración
  # primero, Get Config al final -- BcMotorLive no tiene un tab "Get
  # Config" propio, es "VISUALIZACIÓN DE CAMPOS" adentro de
  # Configuración, así que acá queda último en vez de en el medio):
  #   - Configuración: encabezado (etiqueta/nav/icono/visible, movido acá
  #     2026-08-26 -- mismo lugar que ocupa en BcMotorLive) + grid tipo
  #     "Campos" de BcMotorLive, pero SOLO la etiqueta es editable --
  #     todo lo demás lo definió el catálogo origen, tocarlo acá
  #     rompería el contrato de esa tabla real.
  #   - Contrato: documenta el endpoint REST real
  #     (ConsultaController.index/2, delegado desde CatalogoController).
  #   - Permisos: embebe CatalogoPermisosLive -- ya sabe tratar una
  #     Consulta como solo-lectura (~w(leer)) y muestra su Alcance de
  #     Datos como referencia de solo lectura al de catalogo_base.
  #   - Get Config: qué columnas se ven, en qué orden y con qué
  #     parámetro estándar (Get View de la Consulta).
  #   - SQL: de solo lectura, 2 sub-tabs (SQL real vía
  #     Ecto.Adapters.SQL.to_sql/3, y la Ecto.Query tal cual la arma
  #     MetaConsultas.construir_query_base/1) -- para auditar qué
  #     termina corriendo contra la base, sin filtros/paginación (esos
  #     dependen de cada request, no tiene sentido fijarlos acá).
  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_bc", "editar"}}

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.MetaConsultas
  alias MetadataApp.FiltrosDefault
  alias MetadataAppWeb.AdminNav

  import MetadataAppWeb.SelectorMultipleComponents, only: [selector_multiple: 1]

  import MetadataAppWeb.EncabezadoBcComponents, only: [panel_encabezado: 1]

  alias MetadataAppWeb.EncabezadoBcComponents

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "empresas", label: "Empresas", nav: "/sysadmin/empresas"},
    %{tipo: :pagina, id: "credenciales", label: "Credenciales", nav: "/sysadmin/credenciales"},
    %{tipo: :pagina, id: "ambientes", label: "Ambientes de Deploy", nav: "/sysadmin/ambientes"},
    %{tipo: :pagina, id: "acciones_externas", label: "Acciones externas", nav: "/sysadmin/acciones-externas"},
    %{tipo: :pagina, id: "jerarquia", label: "Jerarquía organizacional", nav: "/sysadmin/jerarquia"},
  %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"}
  ]

  @tabs [
    {"configuracion", "Configuración"},
    {"contrato", "Contrato"},
    {"permisos", "Permisos"},
    {"get_config", "Get Config"},
    {"sql", "SQL"}
  ]

  # Solo estos dos tipos soportan SUM() en SQL (ver totales/2 en
  # MetaConsultas) — "totalizar" ni se ofrece para el resto, para no dejar
  # marcar algo que reventaría la query de la banda de totales al ejecutar
  # el reporte.
  @tipos_totalizables ~w(integer decimal)

  def mount(%{"nombre" => nombre}, _session, socket) do
    socket =
      socket
      |> assign(:current_page, "bc_list")
      |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
      |> assign(:sidebar_open, false)
      |> assign(:show_programacion_children, false)
      |> assign(:show_clientes_children, false)
      |> assign(:show_prettycore_children, false)
      |> assign(:tipos_totalizables, @tipos_totalizables)
      |> assign(:tabs, @tabs)
      |> assign(:tab, "configuracion")
      |> assign(:subtab_sql, "sql")

    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      %{schema_context_type: 3} = header ->
        {:ok, cargar(socket, header)}

      _otro ->
        {:ok,
         socket
         |> put_flash(:error, "Esa consulta no existe.")
         |> push_navigate(to: ~p"/sysadmin/bc-list")}
    end
  end

  defp cargar(socket, header) do
    consulta = MetaConsultas.obtener_por_header_id(header.id)
    campos = Enum.sort_by(consulta.campos, &Map.get(&1, "orden", 0))
    claves_control_actuales = campos |> Enum.filter(&(&1["control"] == true)) |> Enum.map(& &1["campo"]) |> MapSet.new()
    detalles_por_catalogo = MetaSchemaContext.listar_detalles_de_varios(MetaConsultas.catalogos_presentes(consulta))

    socket
    |> assign(:header, header)
    |> assign(:header_form, EncabezadoBcComponents.form_desde_header(header))
    |> assign(:iconos_sugeridos, EncabezadoBcComponents.iconos_sugeridos())
    |> assign(:carpetas, MetaSchemaContext.listar_carpetas_existentes())
    |> assign(:consulta, consulta)
    |> assign(:campos, campos)
    |> assign(:claves_control_disponibles, MetaConsultas.claves_control_disponibles(consulta.catalogo_base))
    |> assign(:claves_control_actuales, claves_control_actuales)
    |> assign(:etiquetas_control, MetaConsultas.etiquetas_control())
    |> assign(:multi_tabla?, consulta.joins != [])
    |> assign(:detalles_por_catalogo, detalles_por_catalogo)
    |> assign(:modos_fecha_rango, FiltrosDefault.modos_fecha_rango())
    |> assign(:modos_fecha_simple, FiltrosDefault.modos_fecha_simple())
    |> assign(:catalogos_referenciables, MetaSchemaContext.listar_catalogos_referenciables())
    |> assign(:orden_por, consulta.orden_por)
    |> assign(:selector_orden_abierto, false)
  end

  defp nil_si_vacio(""), do: nil
  defp nil_si_vacio(valor), do: valor

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "bc_list")
  end

  def handle_event("cambiar_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, tab)}
  end

  def handle_event("cambiar_subtab_sql", %{"subtab" => subtab}, socket) do
    {:noreply, assign(socket, :subtab_sql, subtab)}
  end

  # --- Get Config: encabezado -------------------------------------------
  # Mismo panel/lógica que BcMotorLive (ver EncabezadoBcComponents) --
  # ninguna Consulta necesita nada distinto acá, los 4 campos genéricos
  # son los mismos.

  def handle_event("validar_header", %{"header" => params}, socket) do
    {:noreply, assign(socket, :header_form, EncabezadoBcComponents.validar(params, socket.assigns.header.id))}
  end

  def handle_event("elegir_icono_header", %{"icono" => icono}, socket) do
    {:noreply, update(socket, :header_form, &EncabezadoBcComponents.elegir_icono(&1, icono))}
  end

  def handle_event("guardar_header", %{"header" => params}, socket) do
    case EncabezadoBcComponents.guardar(params, socket.assigns.header) do
      {:ok, header} ->
        {:noreply,
         socket
         |> assign(:header, header)
         |> assign(:header_form, EncabezadoBcComponents.form_desde_header(header))
         |> put_flash(:info, "Encabezado actualizado.")}

      {:error, header_form} ->
        {:noreply, assign(socket, :header_form, header_form)}
    end
  end

  # --- Get Config: columnas (visible/orden/totalizar) -----------------

  # Drag-and-drop (hook ListaOrdenable, mismo componente que
  # BcMotorLive usa en su Get View, ver panel_get_view/1 ahí) -- se
  # persiste al toque, no forma parte del form de "Guardar columnas" de
  # abajo, para que el orden de la lista no dependa de acordarse de
  # guardar aparte.
  def handle_event("mover_a", %{"id" => id, "index" => index}, socket) do
    orden_actual = Enum.map(socket.assigns.campos, &identificador/1)
    nuevo_orden = orden_actual |> List.delete(id) |> List.insert_at(index, id)

    campos =
      nuevo_orden
      |> Enum.map(fn ident -> Enum.find(socket.assigns.campos, &(identificador(&1) == ident)) end)
      |> Enum.with_index()
      |> Enum.map(fn {campo, indice} -> Map.put(campo, "orden", indice) end)

    case MetaConsultas.actualizar_campos(socket.assigns.consulta, campos) do
      {:ok, consulta} ->
        {:noreply, socket |> assign(:consulta, consulta) |> assign(:campos, campos)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo reordenar.")}
    end
  end

  def handle_event("guardar_columnas", params, socket) do
    visibles = params |> Map.get("visibles", []) |> List.wrap() |> MapSet.new()
    totalizar = params |> Map.get("totalizar", []) |> List.wrap() |> MapSet.new()

    campos =
      Enum.map(socket.assigns.campos, fn campo ->
        id = identificador(campo)
        tipo = campo["tipo"]

        campo
        |> Map.put("visible", id in visibles)
        |> Map.put("totalizar", tipo in @tipos_totalizables and id in totalizar)
      end)

    guardar_campos(socket, campos, "Columnas actualizadas.")
  end

  # --- Get Config: campos de control del catálogo base -----------------

  def handle_event("guardar_campos_control", params, socket) do
    claves = params |> Map.get("claves", []) |> List.wrap()

    case MetaConsultas.sincronizar_campos_control(socket.assigns.consulta, claves) do
      {:ok, consulta} ->
        campos = Enum.sort_by(consulta.campos, &Map.get(&1, "orden", 0))

        {:noreply,
         socket
         |> assign(:consulta, consulta)
         |> assign(:campos, campos)
         |> assign(:claves_control_actuales, MapSet.new(claves))
         |> put_flash(:info, "Campos de control actualizados.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo guardar: #{inspect(changeset.errors)}")}
    end
  end

  # --- Get Config: Orden de resultados (R1 admin, 2026-08-27) -----------
  # Cualquier campo de la consulta es elegible, visible o no (ordenar por
  # una columna no la hace aparecer en la tabla) -- a diferencia del resto
  # de este editor, que solo ofrece manejar columnas visibles. Guardado
  # inmediato por acción (agregar/quitar/mover/cambiar dirección), mismo
  # criterio que Parámetro estándar más abajo.

  def handle_event("abrir_selector_orden", _params, socket) do
    {:noreply, assign(socket, :selector_orden_abierto, true)}
  end

  def handle_event("cerrar_selector_orden", _params, socket) do
    {:noreply, assign(socket, :selector_orden_abierto, false)}
  end

  def handle_event("agregar_orden", %{"catalogo" => catalogo, "campo" => campo}, socket) do
    nueva_entrada = %{"catalogo" => catalogo, "campo" => campo, "direccion" => "asc"}
    orden_por = socket.assigns.orden_por ++ [nueva_entrada]

    guardar_orden_por(socket, orden_por, close: true)
  end

  def handle_event("quitar_orden", %{"indice" => indice}, socket) do
    orden_por = List.delete_at(socket.assigns.orden_por, String.to_integer(indice))
    guardar_orden_por(socket, orden_por, close: false)
  end

  def handle_event("cambiar_direccion_orden", %{"indice" => indice}, socket) do
    indice = String.to_integer(indice)

    orden_por =
      List.update_at(socket.assigns.orden_por, indice, fn entrada ->
        Map.put(entrada, "direccion", if(entrada["direccion"] == "desc", do: "asc", else: "desc"))
      end)

    guardar_orden_por(socket, orden_por, close: false)
  end

  def handle_event("mover_orden", %{"indice" => indice, "direccion" => direccion}, socket) do
    indice = String.to_integer(indice)
    destino = if direccion == "arriba", do: indice - 1, else: indice + 1
    orden_por = socket.assigns.orden_por

    if destino >= 0 and destino < length(orden_por) do
      actual = Enum.at(orden_por, indice)
      vecino = Enum.at(orden_por, destino)

      nuevo_orden = orden_por |> List.replace_at(indice, vecino) |> List.replace_at(destino, actual)
      guardar_orden_por(socket, nuevo_orden, close: false)
    else
      {:noreply, socket}
    end
  end

  # --- Get Config: Parámetro estándar por columna (rediseño 2026-08-27) --
  # Guardado inmediato (no forma parte de "Guardar columnas") -- mismo
  # criterio que el resto de los toggles de configuración de este editor.
  # Ver moduledoc de MetaSchema.Consulta para el shape completo de
  # "acotado"/"tipo_filtro"/"origen"/"catalogo_referenciado"/"defaults".
  #
  # Clicks (phx-value-campo) para elecciones cerradas (Acotado/Tipo/
  # Origen/modo de fecha) -- phx-value-* SÍ llega bien en un click (lee
  # del elemento clickeado, ver pushEvent/extractMeta en el cliente JS).
  # `name="clave[<id>]"` + `form="form-guardar-columnas"` para inputs de
  # texto/select con phx-change propio (bug real 2026-08-27: phx-value-*
  # NUNCA llega en un evento de change, solo el name -- ver el comentario
  # grande en panel_get_config/1 más abajo).

  # Segunda barrera server-side (la primera es el botón disabled en
  # toggle_es_parametro/1) -- solo bloquea PRENDER Parámetro en una
  # columna no visible; apagarlo siempre se permite, incluso no visible,
  # para poder limpiar una fila que ya quedó en ese estado inconsistente
  # de antes de este fix (visible:false + es_parametro:true, ver bug real
  # 2026-08-27 en el moduledoc de toggle_es_parametro/1).
  def handle_event("cambiar_es_parametro", %{"campo" => id}, socket) do
    campos =
      mapear_campo(socket, id, fn campo ->
        if campo["visible"] == true or campo["es_parametro"] == true do
          campo |> Map.put("es_parametro", !campo["es_parametro"]) |> Map.put("acotado", false) |> Map.put("tipo_filtro", nil) |> Map.put("origen", nil) |> Map.put("catalogo_referenciado", nil) |> Map.put("defaults", %{})
        else
          campo
        end
      end)

    guardar_campos(socket, campos, "Parámetro actualizado.")
  end

  def handle_event("cambiar_acotado", %{"campo" => id}, socket) do
    campos = mapear_campo(socket, id, fn campo -> campo |> Map.put("acotado", !campo["acotado"]) |> Map.put("tipo_filtro", nil) |> Map.put("defaults", %{}) end)
    guardar_campos(socket, campos, "Acotado actualizado.")
  end

  # <select> (lookup, 2026-08-27 -- reemplaza la fila de botones "Tipo":
  # con 3-4 opciones se amontonaba/enrollaba en la columna angosta de la
  # grilla) -- name-based con form="form-guardar-columnas", mismo motivo
  # que el resto de los controles con phx-change de este panel.
  def handle_event("cambiar_tipo_filtro", %{"tipo_filtro" => mapa}, socket) do
    {id, tipo_filtro} = mapa |> Map.to_list() |> List.first()

    campos =
      mapear_campo(socket, id, fn campo ->
        origen =
          case tipo_filtro do
            "like" -> "libre"
            "multi" -> "referenciado"
            _ -> campo["origen"] || "libre"
          end

        campo |> Map.put("tipo_filtro", tipo_filtro) |> Map.put("origen", origen) |> Map.put("defaults", %{})
      end)

    guardar_campos(socket, campos, "Tipo de filtro actualizado.")
  end

  def handle_event("cambiar_origen", %{"campo" => id, "origen" => origen}, socket) do
    campos = mapear_campo(socket, id, fn campo -> campo |> Map.put("origen", origen) |> Map.put("defaults", %{}) |> Map.put("catalogo_referenciado", nil) end)
    guardar_campos(socket, campos, "Origen actualizado.")
  end

  def handle_event("cambiar_catalogo_referenciado", %{"catalogo_referenciado" => mapa}, socket) do
    {id, catalogo} = mapa |> Map.to_list() |> List.first()
    campos = mapear_campo(socket, id, fn campo -> campo |> Map.put("catalogo_referenciado", nil_si_vacio(catalogo)) |> Map.put("defaults", %{}) end)
    guardar_campos(socket, campos, "Catálogo referenciado actualizado.")
  end

  def handle_event("cambiar_defaults_modo", %{"campo" => id, "modo" => modo}, socket) do
    campos = mapear_campo(socket, id, fn campo -> Map.put(campo, "defaults", %{"modo" => nil_si_vacio(modo)}) end)
    guardar_campos(socket, campos, "Default actualizado.")
  end

  def handle_event("cambiar_defaults_valor", %{"defaults_valor" => mapa}, socket),
    do: aplicar_defaults(socket, mapa, "valor")

  def handle_event("cambiar_defaults_valor_hasta", %{"defaults_valor_hasta" => mapa}, socket),
    do: aplicar_defaults(socket, mapa, "valor_hasta")

  # Lookup multi (SelectorMultipleComponents) -- todos los checkboxes
  # comparten el mismo `name`, así que el cliente manda SIEMPRE la lista
  # completa de los que están tildados (posiblemente vacía si se
  # destildó todo), nunca solo el que se acaba de clickear.
  def handle_event("cambiar_defaults_valores", %{"valores" => mapa}, socket) do
    {id, valores} = mapa |> Map.to_list() |> List.first()
    valores = valores |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))
    campos = mapear_campo(socket, id, fn campo -> Map.put(campo, "defaults", Map.put(campo["defaults"] || %{}, "valores", valores)) end)
    guardar_campos(socket, campos, "Default actualizado.")
  end

  def handle_event("marcar_defaults_todos", %{"campo" => id, "valores" => csv}, socket) do
    valores = csv |> String.split(",") |> Enum.reject(&(&1 == ""))
    campos = mapear_campo(socket, id, fn campo -> Map.put(campo, "defaults", Map.put(campo["defaults"] || %{}, "valores", valores)) end)
    guardar_campos(socket, campos, "Default actualizado.")
  end

  def handle_event("limpiar_defaults_valores", %{"campo" => id}, socket) do
    campos = mapear_campo(socket, id, fn campo -> Map.put(campo, "defaults", Map.put(campo["defaults"] || %{}, "valores", [])) end)
    guardar_campos(socket, campos, "Default actualizado.")
  end

  # --- Configuración: SOLO etiqueta ------------------------------------

  def handle_event("guardar_etiquetas", params, socket) do
    etiquetas = Map.get(params, "etiquetas", %{})

    campos =
      Enum.map(socket.assigns.campos, fn campo ->
        id = identificador(campo)

        etiqueta =
          case Map.get(etiquetas, id) do
            texto when is_binary(texto) and texto != "" -> texto
            _ -> campo["etiqueta"]
          end

        Map.put(campo, "etiqueta", etiqueta)
      end)

    guardar_campos(socket, campos, "Etiquetas actualizadas.")
  end

  defp mapear_campo(socket, id, fun) do
    Enum.map(socket.assigns.campos, fn campo -> if identificador(campo) == id, do: fun.(campo), else: campo end)
  end

  defp aplicar_defaults(socket, mapa, clave) do
    {id, valor} = mapa |> Map.to_list() |> List.first()
    campos = mapear_campo(socket, id, fn campo -> Map.put(campo, "defaults", Map.put(campo["defaults"] || %{}, clave, nil_si_vacio(valor))) end)
    guardar_campos(socket, campos, "Default actualizado.")
  end

  defp guardar_campos(socket, campos, mensaje_ok) do
    case MetaConsultas.actualizar_campos(socket.assigns.consulta, campos) do
      {:ok, consulta} ->
        {:noreply,
         socket
         |> assign(:consulta, consulta)
         |> assign(:campos, Enum.sort_by(campos, &Map.get(&1, "orden", 0)))
         |> put_flash(:info, mensaje_ok)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo guardar: #{inspect(changeset.errors)}")}
    end
  end

  # Identificador único de una fila — dos tablas distintas de la misma
  # consulta pueden tener un campo con el mismo nombre crudo (ej. ambas
  # con "nombre"), así que ni el drag-and-drop (mover_a) ni los <input>
  # del form de abajo pueden usar campo["campo"] solo: "::" no es válido
  # en un nombre de catálogo o de campo, así que nunca puede colisionar.
  defp identificador(campo), do: "#{campo["catalogo"]}::#{campo["campo"]}"

  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto p-6 text-xs font-sans">
      <div class="flex items-start justify-between gap-4 mb-4">
        <div class="flex items-start gap-2">
          <.link navigate={~p"/sysadmin/bc-list"} title="Volver al listado de BC"
            class="mt-0.5 w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors shrink-0">
            <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
          </.link>
          <div>
            <h1 class="text-lg font-bold text-gray-900 flex items-center gap-2">
              <span class="material-symbols-outlined text-purple-600">search</span>
              {@header.schema_context_label}
            </h1>
            <p class="mt-0.5 text-gray-500">
              Consulta Ecto de solo lectura sobre <strong>{Enum.join(MetaConsultas.catalogos_presentes(@consulta), " + ")}</strong> — {@header.schema_context_nav}
            </p>
          </div>
        </div>
        <.link navigate={@header.schema_context_nav} class="shrink-0 font-semibold text-purple-700 hover:underline">
          Ver reporte →
        </.link>
      </div>

      <div class="flex gap-1 border-b border-gray-200 mb-4">
        <button :for={{id, etiqueta} <- @tabs} type="button" phx-click="cambiar_tab" phx-value-tab={id}
          class={[
            "px-3 py-2 text-sm font-semibold border-b-2 -mb-px",
            @tab == id && "border-purple-600 text-purple-700",
            @tab != id && "border-transparent text-gray-500 hover:text-gray-700"
          ]}>
          {etiqueta}
        </button>
      </div>

      <.panel_get_config :if={@tab == "get_config"} campos={@campos}
        multi_tabla?={@multi_tabla?} tipos_totalizables={@tipos_totalizables}
        claves_control_disponibles={@claves_control_disponibles} claves_control_actuales={@claves_control_actuales}
        etiquetas_control={@etiquetas_control} consulta={@consulta} detalles_por_catalogo={@detalles_por_catalogo}
        modos_fecha_rango={@modos_fecha_rango} modos_fecha_simple={@modos_fecha_simple} catalogos_referenciables={@catalogos_referenciables}
        orden_por={@orden_por} selector_orden_abierto={@selector_orden_abierto} />
      <.panel_configuracion :if={@tab == "configuracion"} campos={@campos} multi_tabla?={@multi_tabla?}
        header_form={@header_form} iconos_sugeridos={@iconos_sugeridos} carpetas={@carpetas} />
      <.panel_contrato :if={@tab == "contrato"} header={@header} campos={@campos} />
      <.panel_permisos :if={@tab == "permisos"} header={@header} socket={@socket} />
      <.panel_sql :if={@tab == "sql"} consulta={@consulta} subtab_sql={@subtab_sql} />
    </div>
    """
  end

  attr :campos, :list, required: true
  attr :multi_tabla?, :boolean, required: true
  attr :tipos_totalizables, :list, required: true
  attr :claves_control_disponibles, :list, required: true
  attr :claves_control_actuales, :any, required: true
  attr :etiquetas_control, :map, required: true
  attr :consulta, :map, required: true
  attr :detalles_por_catalogo, :map, required: true
  attr :modos_fecha_rango, :list, required: true
  attr :modos_fecha_simple, :list, required: true
  attr :catalogos_referenciables, :list, required: true
  attr :orden_por, :list, required: true
  attr :selector_orden_abierto, :boolean, required: true

  defp panel_get_config(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%!-- Las 3 secciones de Get Config son acordeones (2026-08-28, a
      pedido explícito -- "permite mejor administración") -- <details>/
      <summary> nativo + el hook RecordarSeccion, mismo patrón exacto que
      panel_parametros/1 en catalogo_live.ex (recuerda open/closed en
      localStorage por id, sin round-trip al servidor). Empiezan CERRADAS
      la primera vez (sin atributo `open`, a pedido explícito). Ids fijos
      (no por Consulta) a propósito -- a diferencia de Parámetros (cuyo
      contenido varía mucho de una Consulta a otra), estas 3 secciones son
      siempre la misma estructura sea cual sea la Consulta, así que la
      preferencia de qué tener abierto/cerrado tiene más sentido como algo
      global del admin, no algo que se resetea en cada Consulta distinta. --%>
      <details id="get-config-columnas" phx-hook="RecordarSeccion" class="group bg-white border border-gray-200 rounded-2xl shadow-sm">
        <summary class="px-4 py-3 text-[11px] font-bold uppercase tracking-wide text-gray-400 flex items-center gap-1.5 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
          <span class="material-symbols-outlined text-gray-400 transition-transform group-open:rotate-90" style="font-size: 15px">chevron_right</span>
          <span class="material-symbols-outlined" style="font-size: 15px">view_column</span>
          Columnas del GET (orden, visibilidad, totales, parámetro)
        </summary>

        <%!-- phx-value-* NUNCA llega en un evento de "change" disparado
        por un <select>/<input> (el cliente JS de LiveView solo lo lee de
        un elemento en eventos de click/genéricos) -- ver el comentario
        grande sobre "cambiar_acotado" en el bloque de handlers. Por eso
        cada control de change acá usa `name="clave[<id>]"` +
        `form="form-guardar-columnas"` en vez de phx-value-campo, mismo
        patrón que filtros[campo] en catalogo_live.ex/fila_filtro_columna
        -- y como viven sueltos (sin <form> ancestro), el atributo
        `form=""` es obligatorio para que el cliente les resuelva `.form`,
        si no revienta con "form events require the input to be inside a
        form" al primer change. --%>
        <form id="form-guardar-columnas" phx-submit="guardar_columnas" class="hidden" aria-hidden="true"></form>

        <div class="overflow-x-auto rounded-t-2xl mt-2">
          <table class="min-w-full divide-y divide-gray-200 text-xs">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-1 py-1.5"></th>
                <th :if={@multi_tabla?} class="px-1.5 py-1.5 text-left font-semibold text-gray-500 uppercase tracking-wide">Tabla</th>
                <th class="px-1.5 py-1.5 text-left font-semibold text-gray-500 uppercase tracking-wide">Campo</th>
                <th class="px-1.5 py-1.5 text-left font-semibold text-gray-500 uppercase tracking-wide">Etq</th>
                <th class="px-1.5 py-1.5 text-center font-semibold text-gray-500 uppercase tracking-wide">Vis.</th>
                <th class="px-1.5 py-1.5 text-center font-semibold text-gray-500 uppercase tracking-wide">Tot.</th>
                <th class="px-1.5 py-1.5 text-center font-semibold text-gray-500 uppercase tracking-wide">Param</th>
                <th class="px-1.5 py-1.5 text-left font-semibold text-gray-500 uppercase tracking-wide">Tipo</th>
                <th class="px-1.5 py-1.5 text-center font-semibold text-gray-500 uppercase tracking-wide">Acot.</th>
                <th class="px-1.5 py-1.5 text-left font-semibold text-gray-500 uppercase tracking-wide">Default</th>
              </tr>
            </thead>
            <tbody id="consulta-columnas-get-ordenable" phx-hook="ListaOrdenable" data-grupo="consulta-columnas-get" class="divide-y divide-gray-100">
              <tr :for={campo <- @campos} id={"columna-get-row-#{identificador(campo)}"} data-id={identificador(campo)}>
                <td class="px-1 py-1.5 text-gray-300 jal-manija cursor-grab" title="Arrastrar para reordenar">
                  <span class="material-symbols-outlined" style="font-size: 14px">drag_indicator</span>
                </td>
                <td :if={@multi_tabla?} class="px-1.5 py-1.5 text-gray-500 font-mono max-w-[7rem] truncate" title={campo["catalogo"]}>{campo["catalogo"]}</td>
                <td class="px-1.5 py-1.5 text-gray-500 font-mono max-w-[9rem] truncate" title={campo["campo"]}>{campo["campo"]}</td>
                <td class="px-1.5 py-1.5 text-gray-700 max-w-[6rem] truncate" title={campo["etiqueta"]}>{campo["etiqueta"]}</td>
                <td class="px-1.5 py-1.5 text-center">
                  <input type="checkbox" form="form-guardar-columnas" name="visibles[]" value={identificador(campo)} checked={campo["visible"]} class="accent-purple-600" />
                </td>
                <td class="px-1.5 py-1.5 text-center">
                  <input type="checkbox" form="form-guardar-columnas" name="totalizar[]" value={identificador(campo)} checked={campo["totalizar"]}
                    disabled={campo["tipo"] not in @tipos_totalizables}
                    title={if campo["tipo"] not in @tipos_totalizables, do: "Solo campos numéricos se pueden totalizar"}
                    class="accent-purple-600 disabled:opacity-20" />
                </td>
                <td class="px-1.5 py-1.5 text-center">
                  <.toggle_es_parametro :if={MetaConsultas.tipo_elegible?(MetaConsultas.tipo_efectivo(campo))} campo={campo} id={identificador(campo)} />
                  <span :if={!MetaConsultas.tipo_elegible?(MetaConsultas.tipo_efectivo(campo))} class="text-[10px] text-gray-300" title="Tipo sin parámetro estándar">—</span>
                </td>
                <.celdas_parametro campo={campo} tipo_efectivo={MetaConsultas.tipo_efectivo(campo)} modos_fecha_rango={@modos_fecha_rango} modos_fecha_simple={@modos_fecha_simple}
                  catalogos_referenciables={@catalogos_referenciables} detalles_por_catalogo={@detalles_por_catalogo} />
              </tr>
              <tr :if={@campos == []}>
                <td colspan={if @multi_tabla?, do: 10, else: 9} class="px-1.5 py-6 text-center text-gray-400">Esta consulta no tiene campos.</td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="px-4 py-3 border-t border-gray-200">
          <button type="submit" form="form-guardar-columnas" class="px-4 py-2 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
            Guardar columnas
          </button>
        </div>
      </details>

      <details id="get-config-campos-control" phx-hook="RecordarSeccion" class="group bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <summary class="text-[11px] font-bold uppercase tracking-wide text-gray-400 flex items-center gap-1.5 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
          <span class="material-symbols-outlined text-gray-400 transition-transform group-open:rotate-90" style="font-size: 15px">chevron_right</span>
          <span class="material-symbols-outlined" style="font-size: 15px">settings</span>
          Campos de control del catálogo base
        </summary>
        <p class="text-xs text-gray-400 mb-3 mt-2">Solo se ofrecen los que tienen sentido para este catálogo (Estado si adoptó el motor de estados, TRN si es transaccional, Sucursal/Almacén/Unidad de venta si tiene Alcance de Datos).</p>
        <form phx-submit="guardar_campos_control" class="flex flex-col gap-3">
          <div :if={@claves_control_disponibles == []} class="text-xs text-gray-400">Este catálogo no tiene campos de control disponibles.</div>
          <label :for={clave <- @claves_control_disponibles} class="flex items-center gap-1.5 text-sm text-gray-700">
            <input type="checkbox" name="claves[]" value={clave} checked={clave in @claves_control_actuales} class="accent-purple-600" />
            {Map.fetch!(@etiquetas_control, clave)}
          </label>
          <div>
            <button type="submit" class="px-4 py-2 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
              Guardar campos de control
            </button>
          </div>
        </form>
      </details>

      <details id="get-config-orden" phx-hook="RecordarSeccion" class="group bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <summary class="text-[11px] font-bold uppercase tracking-wide text-gray-400 flex items-center gap-1.5 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
          <span class="material-symbols-outlined text-gray-400 transition-transform group-open:rotate-90" style="font-size: 15px">chevron_right</span>
          <span class="material-symbols-outlined" style="font-size: 15px">sort</span>
          Orden de resultados
        </summary>
        <p class="text-xs text-gray-400 mb-3 mt-2">
          Define en qué orden salen las filas del reporte — la primera columna manda, las siguientes desempatan.
          Cualquier columna de la consulta sirve, esté visible o no.
        </p>

        <ul :if={@orden_por != []} class="flex flex-col gap-1.5 mb-3">
          <li :for={{entrada, indice} <- Enum.with_index(@orden_por)} class="flex items-center gap-2 bg-gray-50 border border-gray-200 rounded-lg px-2.5 py-1.5">
            <span class="text-gray-400 font-mono w-4 text-center flex-shrink-0">{indice + 1}</span>
            <span class="flex-1 min-w-0 text-gray-900 truncate">{etiqueta_orden(@campos, entrada)}</span>
            <button type="button" phx-click="cambiar_direccion_orden" phx-value-indice={indice}
              class={[
                "px-2 py-0.5 rounded text-[11px] font-semibold flex-shrink-0",
                entrada["direccion"] == "desc" && "bg-purple-100 text-purple-700",
                entrada["direccion"] != "desc" && "bg-gray-100 text-gray-600"
              ]}>
              {if entrada["direccion"] == "desc", do: "Descendente", else: "Ascendente"}
            </button>
            <button type="button" phx-click="mover_orden" phx-value-indice={indice} phx-value-direccion="arriba" disabled={indice == 0}
              class="w-6 h-6 rounded border border-gray-300 text-gray-500 hover:bg-gray-100 disabled:opacity-30 disabled:cursor-not-allowed flex-shrink-0" title="Subir prioridad">↑</button>
            <button type="button" phx-click="mover_orden" phx-value-indice={indice} phx-value-direccion="abajo" disabled={indice == length(@orden_por) - 1}
              class="w-6 h-6 rounded border border-gray-300 text-gray-500 hover:bg-gray-100 disabled:opacity-30 disabled:cursor-not-allowed flex-shrink-0" title="Bajar prioridad">↓</button>
            <button type="button" phx-click="quitar_orden" phx-value-indice={indice}
              class="w-6 h-6 rounded border border-gray-300 text-red-600 hover:bg-red-50 flex-shrink-0" title="Quitar del orden">×</button>
          </li>
        </ul>
        <p :if={@orden_por == []} class="text-xs text-gray-400 mb-3">Sin orden configurado — el reporte sale en el orden que devuelva la base, sin garantía.</p>

        <div class="relative inline-block">
          <button type="button" phx-click="abrir_selector_orden" class="text-purple-700 hover:text-purple-900 font-semibold text-sm">
            + Agregar columna de orden
          </button>
          <%= if @selector_orden_abierto do %>
            <div class="fixed inset-0 z-40" phx-click="cerrar_selector_orden"></div>
            <%!-- Abre hacia ARRIBA (bottom-full, no top-full) -- esta es la
            última sección de Get Config, casi siempre pegada al borde de
            abajo de la ventana; abriendo hacia abajo el popover quedaba
            cortado contra el viewport, sin espacio para desplegar (bug
            real 2026-08-27, "no puedo ordenar porque no se ve el
            control"). Mismo motivo por el que no puede haber otro
            popover ABAJO de este en la página. --%>
            <div class="absolute left-0 bottom-full mb-1 w-64 max-h-56 overflow-y-auto bg-white border border-gray-200 rounded-lg shadow-lg z-50 py-1">
              <button :for={c <- campos_disponibles_orden(@campos, @orden_por)} type="button"
                phx-click="agregar_orden" phx-value-catalogo={c["catalogo"]} phx-value-campo={c["campo"]}
                class="w-full text-left px-3 py-1.5 text-gray-700 hover:bg-purple-50 hover:text-purple-700 text-xs">
                {c["etiqueta"]} <span :if={@multi_tabla?} class="text-gray-400 font-mono">· {c["catalogo"]}</span>
              </button>
              <p :if={campos_disponibles_orden(@campos, @orden_por) == []} class="px-3 py-2 text-gray-400 text-xs">Ya agregaste todas las columnas.</p>
            </div>
          <% end %>
        </div>
      </details>

    </div>
    """
  end

  defp etiqueta_orden(campos, %{"catalogo" => catalogo, "campo" => campo}) do
    case Enum.find(campos, &(&1["catalogo"] == catalogo and &1["campo"] == campo)) do
      nil -> "#{catalogo}.#{campo} (columna eliminada)"
      campo_def -> campo_def["etiqueta"]
    end
  end

  defp campos_disponibles_orden(campos, orden_por) do
    ya_usados = MapSet.new(orden_por, &{&1["catalogo"], &1["campo"]})
    Enum.reject(campos, &MapSet.member?(ya_usados, {&1["catalogo"], &1["campo"]}))
  end

  defp guardar_orden_por(socket, orden_por, opciones) do
    case MetaConsultas.actualizar_orden_por(socket.assigns.consulta, orden_por) do
      {:ok, consulta} ->
        socket =
          socket
          |> assign(:consulta, consulta)
          |> assign(:orden_por, consulta.orden_por)

        socket = if opciones[:close], do: assign(socket, :selector_orden_abierto, false), else: socket
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo guardar el orden: #{inspect(changeset.errors)}")}
    end
  end

  # --- Get Config: 4 celdas de Parámetro (Tipo/Es acotado/Parámetro/
  # Defaults), una por fila, dispatched por tipo (ver moduledoc de
  # MetaSchema.Consulta para el shape completo). Un campo NO visible o de
  # tipo no elegible (boolean/enum/nil) cae en el fallback: 4 celdas
  # apagadas, nada configurable -- MetaConsultas.tipo_elegible?/1 es la
  # MISMA regla que usa el motor para decidir si un campo participa de
  # Parámetro estándar, así la grilla nunca puede mostrar interactivo algo
  # que el motor de todos modos va a ignorar.
  attr :campo, :map, required: true
  attr :tipo_efectivo, :any, required: true, doc: "MetaConsultas.tipo_efectivo/1 -- branch/inventory_location/sales_unit (campos de control) son \"referencia\" aunque campo[\"tipo\"] guardado sea nil"
  attr :modos_fecha_rango, :list, required: true
  attr :modos_fecha_simple, :list, required: true
  attr :catalogos_referenciables, :list, required: true
  attr :detalles_por_catalogo, :map, required: true

  defp celdas_parametro(%{campo: %{"visible" => true, "es_parametro" => true}, tipo_efectivo: "date"} = assigns) do
    id = identificador(assigns.campo)
    assigns = assign(assigns, :id, id)

    ~H"""
    <td class="px-1.5 py-1.5 text-gray-500">Fecha</td>
    <td class="px-1.5 py-1.5 text-center"><.toggle_acotado campo={@campo} id={@id} /></td>
    <td class="px-1.5 py-1.5"><.defaults_fecha campo={@campo} id={@id} modos_fecha_rango={@modos_fecha_rango} modos_fecha_simple={@modos_fecha_simple} /></td>
    """
  end

  # "Origen" (libre vs. catálogo referenciado) se sacó de columna propia
  # (2026-08-28, a pedido explícito -- "no aporta valor" como columna
  # aparte) y se juntó dentro de la celda de "Defaults", justo arriba del
  # valor por default -- están acopladas de todos modos (defaults_string/1
  # YA rama por `origen` para "igual", ver abajo), tenerlas separadas en
  # columnas distintas no sumaba nada, solo hacía la tabla más ancha.
  defp celdas_parametro(%{campo: %{"visible" => true, "es_parametro" => true}, tipo_efectivo: tipo} = assigns) when tipo in ~w(string referencia) do
    id = identificador(assigns.campo)
    tipo_filtro = assigns.campo["tipo_filtro"] || "like"
    origen = if tipo == "referencia", do: "referenciado", else: assigns.campo["origen"] || "libre"
    assigns = assigns |> assign(:id, id) |> assign(:tipo_filtro, tipo_filtro) |> assign(:origen, origen) |> assign(:es_referencia_real?, tipo == "referencia")

    ~H"""
    <td class="px-1.5 py-1.5">
      <.selector_tipo_filtro id={@id} valor={@tipo_filtro} opciones={[{"like", "Contiene"}, {"igual", "Igual"}, {"multi", "Múltiple"}]} />
    </td>
    <td class="px-1.5 py-1.5 text-center text-[10px] text-gray-300" title="String nunca es acotado">No</td>
    <td class="px-1.5 py-1.5">
      <.origen_string campo={@campo} id={@id} tipo_filtro={@tipo_filtro} origen={@origen} es_referencia_real?={@es_referencia_real?} catalogos_referenciables={@catalogos_referenciables} />
      <.defaults_string campo={@campo} id={@id} tipo_filtro={@tipo_filtro} origen={@origen} detalles_por_catalogo={@detalles_por_catalogo} />
    </td>
    """
  end

  defp celdas_parametro(%{campo: %{"visible" => true, "es_parametro" => true}, tipo_efectivo: tipo} = assigns) when tipo in ~w(integer decimal) do
    id = identificador(assigns.campo)
    acotado = assigns.campo["acotado"] || false
    tipo_filtro = if acotado, do: "entre", else: assigns.campo["tipo_filtro"] || "mayor"
    assigns = assigns |> assign(:id, id) |> assign(:acotado, acotado) |> assign(:tipo_filtro, tipo_filtro)

    ~H"""
    <td class="px-1.5 py-1.5">
      <span :if={@acotado} class="text-[10px] text-gray-500">Entre</span>
      <.selector_tipo_filtro :if={!@acotado} id={@id} valor={@tipo_filtro} opciones={[{"mayor", "Mayor que"}, {"menor", "Menor que"}, {"igual", "Igual"}, {"diferente", "Diferente de"}]} />
    </td>
    <td class="px-1.5 py-1.5 text-center"><.toggle_acotado campo={@campo} id={@id} /></td>
    <td class="px-1.5 py-1.5"><.defaults_numerico campo={@campo} id={@id} acotado={@acotado} /></td>
    """
  end

  defp celdas_parametro(assigns) do
    ~H"""
    <td colspan="3" class="px-1.5 py-1.5 text-center text-gray-300" title="No visible o tipo sin parámetro estándar">—</td>
    """
  end

  attr :campo, :map, required: true
  attr :id, :string, required: true

  # Gate explícito: un campo elegible por tipo NO es parámetro del
  # reporte hasta que el admin lo prenda acá a propósito (corrección
  # 2026-08-27 -- "no todas las columnas llevan parámetro, solo las que
  # indico que llevan"). Ver MetaConsultas.campos_elegibles_fecha/1 y
  # análogas, que exigen este flag además de tipo+visible.
  #
  # Bug real 2026-08-27: este botón no chequeaba "visible", así que se
  # podía prender Parámetro en una columna todavía NO visible -- quedaba
  # es_parametro:true + visible:false persistido, una combinación que
  # celdas_parametro/1 nunca renderiza como interactivo (esa exige
  # "visible" => true en su guard, ver el clause de arriba), así que
  # "Acotado" no aparecía nunca aunque Parámetro ya dijera "Sí" --
  # confuso, parecía roto. "Visible" se guarda recién al tocar "Guardar
  # columnas" (form aparte, ver arriba) -- por eso el mensaje le dice al
  # admin exactamente qué hacer primero, no solo que está deshabilitado.
  defp toggle_es_parametro(assigns) do
    ~H"""
    <button type="button" phx-click="cambiar_es_parametro" phx-value-campo={@id}
      disabled={@campo["visible"] != true}
      title={if @campo["visible"] != true, do: "Primero marcá \"Visible\" y guardá columnas -- Parámetro exige que la columna sea visible"}
      class={[
        "text-[10px] font-semibold rounded-full px-2 py-1",
        @campo["es_parametro"] && "bg-purple-600 text-white",
        !@campo["es_parametro"] && "bg-gray-100 text-gray-500 hover:bg-gray-200",
        @campo["visible"] != true && "opacity-40 cursor-not-allowed"
      ]}>
      {if @campo["es_parametro"], do: "Sí", else: "No"}
    </button>
    """
  end

  attr :id, :string, required: true
  attr :valor, :string, required: true
  attr :opciones, :list, required: true

  # Lookup compacto (2026-08-27) -- reemplaza la fila de botones "Tipo":
  # con 3-4 opciones se amontonaba/enrollaba en la columna angosta de la
  # grilla. Un <select> ya es de una sola línea de por sí, no hace falta
  # el popover con checkboxes (SelectorMultipleComponents) -- acá es
  # elección única, no múltiple.
  defp selector_tipo_filtro(assigns) do
    ~H"""
    <select phx-change="cambiar_tipo_filtro" form="form-guardar-columnas" name={"tipo_filtro[#{@id}]"}
      class="border border-gray-300 rounded-lg text-[11px] px-2 py-1">
      <option :for={{valor, etiqueta} <- @opciones} value={valor} selected={valor == @valor}>{etiqueta}</option>
    </select>
    """
  end

  defp toggle_acotado(assigns) do
    ~H"""
    <button type="button" phx-click="cambiar_acotado" phx-value-campo={@id}
      class={[
        "text-[10px] font-semibold rounded-full px-2 py-1",
        @campo["acotado"] && "bg-purple-600 text-white",
        !@campo["acotado"] && "bg-gray-100 text-gray-500 hover:bg-gray-200"
      ]}>
      {if @campo["acotado"], do: "Sí", else: "No"}
    </button>
    """
  end

  attr :campo, :map, required: true
  attr :id, :string, required: true
  attr :modos_fecha_rango, :list, required: true
  attr :modos_fecha_simple, :list, required: true

  defp defaults_fecha(assigns) do
    modos = if assigns.campo["acotado"], do: assigns.modos_fecha_rango, else: assigns.modos_fecha_simple
    defaults = assigns.campo["defaults"] || %{}
    assigns = assigns |> assign(:modos, modos) |> assign(:defaults, defaults)

    ~H"""
    <div class="flex flex-col gap-1">
      <div class="flex items-center gap-1 flex-wrap">
        <button :for={{modo, etiqueta} <- @modos} type="button"
          phx-click="cambiar_defaults_modo" phx-value-campo={@id} phx-value-modo={modo}
          class={[
            "text-[10px] font-semibold rounded-full px-2 py-1 whitespace-nowrap",
            (@defaults["modo"] || "") == modo && "bg-purple-600 text-white",
            (@defaults["modo"] || "") != modo && "bg-purple-50 text-purple-700 hover:bg-purple-100"
          ]}>
          {etiqueta}
        </button>
      </div>

      <div :if={@defaults["modo"] == "formula" && @campo["acotado"]} class="flex items-center gap-1 mt-1">
        <input type="text" value={@defaults["valor"]} placeholder="primer_dia_mes"
          phx-change="cambiar_defaults_valor" form="form-guardar-columnas" name={"defaults_valor[#{@id}]"}
          class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-20" />
        <span class="text-gray-400 text-[10px]">–</span>
        <input type="text" value={@defaults["valor_hasta"]} placeholder="actual"
          phx-change="cambiar_defaults_valor_hasta" form="form-guardar-columnas" name={"defaults_valor_hasta[#{@id}]"}
          class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-20" />
      </div>

      <input :if={@defaults["modo"] == "formula" && !@campo["acotado"]} type="text" value={@defaults["valor"]} placeholder="ej. actual - 3 meses"
        phx-change="cambiar_defaults_valor" form="form-guardar-columnas" name={"defaults_valor[#{@id}]"}
        class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-full mt-1" />
    </div>
    """
  end

  attr :campo, :map, required: true
  attr :id, :string, required: true
  attr :tipo_filtro, :string, required: true
  attr :origen, :string, required: true
  attr :es_referencia_real?, :boolean, required: true
  attr :catalogos_referenciables, :list, required: true

  defp origen_string(%{es_referencia_real?: true} = assigns) do
    ~H"""
    <span class="text-[10px] text-gray-500">Referenciado</span>
    """
  end

  defp origen_string(%{tipo_filtro: "like"} = assigns) do
    ~H"""
    <span class="text-[10px] text-gray-500">Libre</span>
    """
  end

  defp origen_string(%{tipo_filtro: "multi"} = assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <span class="text-[10px] text-gray-500">Referenciado</span>
      <.selector_catalogo id={@id} valor={@campo["catalogo_referenciado"]} catalogos_referenciables={@catalogos_referenciables} />
    </div>
    """
  end

  defp origen_string(%{tipo_filtro: "igual"} = assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div class="flex gap-1">
        <button :for={{valor, etiqueta} <- [{"libre", "Libre"}, {"referenciado", "Referenciado"}]} type="button"
          phx-click="cambiar_origen" phx-value-campo={@id} phx-value-origen={valor}
          class={[
            "text-[10px] font-semibold rounded-full px-2 py-1",
            @origen == valor && "bg-purple-600 text-white",
            @origen != valor && "bg-purple-50 text-purple-700 hover:bg-purple-100"
          ]}>
          {etiqueta}
        </button>
      </div>
      <.selector_catalogo :if={@origen == "referenciado"} id={@id} valor={@campo["catalogo_referenciado"]} catalogos_referenciables={@catalogos_referenciables} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :valor, :any, required: true
  attr :catalogos_referenciables, :list, required: true

  defp selector_catalogo(assigns) do
    ~H"""
    <select phx-change="cambiar_catalogo_referenciado" form="form-guardar-columnas" name={"catalogo_referenciado[#{@id}]"}
      class="border border-gray-300 rounded text-[10px] px-1.5 py-0.5">
      <option value="" selected={@valor in [nil, ""]}>— elegir catálogo —</option>
      <option :for={c <- @catalogos_referenciables} value={c.nombre} selected={c.nombre == @valor}>{c.etiqueta}</option>
    </select>
    """
  end

  attr :campo, :map, required: true
  attr :id, :string, required: true
  attr :tipo_filtro, :string, required: true
  attr :origen, :string, required: true
  attr :detalles_por_catalogo, :map, required: true

  # "like" y "igual"+libre -- caja de texto para un default fijo.
  defp defaults_string(%{tipo_filtro: tipo_filtro, origen: origen} = assigns) when tipo_filtro == "like" or (tipo_filtro == "igual" and origen == "libre") do
    defaults = assigns.campo["defaults"] || %{}
    assigns = assign(assigns, :valor, defaults["valor"])

    ~H"""
    <input type="text" value={@valor} placeholder="Default (opcional)"
      phx-change="cambiar_defaults_valor" form="form-guardar-columnas" name={"defaults_valor[#{@id}]"}
      class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-full" />
    """
  end

  # "igual"+referenciado (incluye tipo "referencia" real) -- un <select>
  # con los valores reales del catálogo, no una caja de texto libre.
  defp defaults_string(%{tipo_filtro: "igual"} = assigns) do
    opciones = opciones_catalogo_referenciado(assigns.campo, assigns.detalles_por_catalogo)
    defaults = assigns.campo["defaults"] || %{}
    assigns = assigns |> assign(:opciones, opciones) |> assign(:valor, defaults["valor"])

    ~H"""
    <select phx-change="cambiar_defaults_valor" form="form-guardar-columnas" name={"defaults_valor[#{@id}]"}
      class="border border-gray-300 rounded text-[11px] px-1.5 py-0.5 w-full">
      <option value="" selected={@valor in [nil, ""]}>— sin default —</option>
      <option :for={{val, etiqueta} <- @opciones} value={val} selected={to_string(val) == to_string(@valor)}>{etiqueta}</option>
    </select>
    """
  end

  # "multi" -- lookup con checkbox a la izquierda (MetadataAppWeb.SelectorMultipleComponents),
  # reemplaza el <select multiple> nativo (2026-08-27, a pedido explícito
  # -- ctrl/cmd+click no es discoverable).
  defp defaults_string(%{tipo_filtro: "multi"} = assigns) do
    opciones = opciones_catalogo_referenciado(assigns.campo, assigns.detalles_por_catalogo)
    defaults = assigns.campo["defaults"] || %{}
    valores = Enum.map(defaults["valores"] || [], &to_string/1)
    assigns = assigns |> assign(:opciones, opciones) |> assign(:valores, valores)

    ~H"""
    <.selector_multiple id={"defaults-#{@id}"} form_id="form-guardar-columnas"
      evento="cambiar_defaults_valores" evento_todos="marcar_defaults_todos" evento_ninguno="limpiar_defaults_valores"
      campo_clave={@id} opciones={@opciones} seleccionados={@valores} />
    """
  end

  defp opciones_catalogo_referenciado(campo, detalles_por_catalogo) do
    case MetaConsultas.props_referenciado(campo, detalles_por_catalogo) do
      nil -> []
      props -> CatalogoGenerico.opciones_referencia(props, %{}, nil)
    end
  end

  attr :campo, :map, required: true
  attr :id, :string, required: true
  attr :acotado, :boolean, required: true

  defp defaults_numerico(assigns) do
    defaults = assigns.campo["defaults"] || %{}
    assigns = assign(assigns, :defaults, defaults)

    ~H"""
    <div :if={@acotado} class="flex items-center gap-1">
      <input type="number" step="any" value={@defaults["valor"]} placeholder="Desde"
        phx-change="cambiar_defaults_valor" form="form-guardar-columnas" name={"defaults_valor[#{@id}]"}
        class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-20" />
      <span class="text-gray-400 text-[10px]">–</span>
      <input type="number" step="any" value={@defaults["valor_hasta"]} placeholder="Hasta"
        phx-change="cambiar_defaults_valor_hasta" form="form-guardar-columnas" name={"defaults_valor_hasta[#{@id}]"}
        class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-20" />
    </div>
    <input :if={!@acotado} type="number" step="any" value={@defaults["valor"]} placeholder="Default (opcional)"
      phx-change="cambiar_defaults_valor" form="form-guardar-columnas" name={"defaults_valor[#{@id}]"}
      class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-full" />
    """
  end

  attr :campos, :list, required: true
  attr :multi_tabla?, :boolean, required: true
  attr :header_form, :map, required: true
  attr :iconos_sugeridos, :list, required: true
  attr :carpetas, :list, required: true

  defp panel_configuracion(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <.panel_encabezado header_form={@header_form} iconos_sugeridos={@iconos_sugeridos} carpetas={@carpetas} />

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm">
        <div class="px-4 pt-4 text-[11px] font-bold uppercase tracking-wide text-gray-400">
          Campos — solo la etiqueta es editable (tipo/origen los define el catálogo real)
        </div>
        <form phx-submit="guardar_etiquetas">
          <div class="overflow-x-auto rounded-t-2xl mt-2">
            <table class="min-w-full divide-y divide-gray-200 text-xs">
              <thead class="bg-gray-50">
                <tr>
                  <th :if={@multi_tabla?} class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">Tabla</th>
                  <th class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">Campo</th>
                  <th class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">Tipo</th>
                  <th class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">Etiqueta</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :for={campo <- @campos}>
                  <td :if={@multi_tabla?} class="px-3 py-2 text-gray-500 font-mono">{campo["catalogo"]}</td>
                  <td class="px-3 py-2 text-gray-500 font-mono">{campo["campo"]}</td>
                  <td class="px-3 py-2 text-gray-400">{campo["tipo"]}</td>
                  <td class="px-3 py-2">
                    <input type="text" name={"etiquetas[#{identificador(campo)}]"} value={campo["etiqueta"]}
                      class="w-full border border-gray-300 rounded px-2 py-1 text-gray-900" />
                  </td>
                </tr>
                <tr :if={@campos == []}>
                  <td colspan={if @multi_tabla?, do: 4, else: 3} class="px-3 py-6 text-center text-gray-400">Esta consulta no tiene campos.</td>
                </tr>
              </tbody>
            </table>
          </div>
          <div class="px-4 py-3 border-t border-gray-200 flex justify-end">
            <button type="submit" class="px-4 py-2 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
              Guardar etiquetas
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :header, :map, required: true
  attr :campos, :list, required: true

  defp panel_contrato(assigns) do
    campo_filtro = Enum.find(assigns.campos, &(&1["visible"] == true and &1["control"] != true))

    ejemplo_json = """
    {
      "meta_campos": [
        { "clave": "<catalogo>__<campo>", "catalogo": "...", "campo": "...", "etiqueta": "...", "tipo": "..." },
        ...
      ],
      "data": [
        { "<catalogo>__<campo>": <valor>, ... },
        ...
      ],
      "totales": { "<catalogo>__<campo>": <suma>, ... },
      "paginacion": { "pagina": 1, "por_pagina": 25, "total_filas": 0, "total_paginas": 1 }
    }
    """

    assigns = assigns |> assign(:campo_filtro, campo_filtro) |> assign(:ejemplo_json, ejemplo_json)

    ~H"""
    <div class="flex flex-col gap-4">
      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Endpoint</div>
        <div class="flex items-center gap-2 mb-3">
          <span class="text-[10px] font-bold px-1.5 py-0.5 rounded bg-emerald-100 text-emerald-700">GET</span>
          <code class="font-mono text-xs bg-gray-100 px-2 py-1 rounded">/api/{@header.schema_context_name}</code>
        </div>
        <p class="text-xs text-gray-500">
          De solo lectura — no existen <code class="font-mono">POST</code>/<code class="font-mono">PUT</code>/<code class="font-mono">DELETE</code> para una Consulta, nunca transacciona.
          Requiere la misma sesión/autenticación que el resto de la API (<code class="font-mono">/api/*</code>).
        </p>
      </div>

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Parámetros (query string)</div>
        <table class="min-w-full text-xs">
          <tbody class="divide-y divide-gray-100">
            <tr>
              <td class="py-1.5 pr-4 font-mono text-gray-700">pagina</td>
              <td class="py-1.5 text-gray-500">Página a traer. Default 1.</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-4 font-mono text-gray-700">por_pagina</td>
              <td class="py-1.5 text-gray-500">Filas por página. Default 25, máximo 100.</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-4 font-mono text-gray-700">&lt;campo&gt;=&lt;valor&gt;</td>
              <td class="py-1.5 text-gray-500">
                Filtro de igualdad exacta contra cualquier columna del Get Config (visible o no) — nombre crudo del campo, sin el catálogo delante.
                Si dos tablas unidas tienen un campo con el mismo nombre, filtra ambas por igual (misma limitación que la tabla admin).
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Ejemplos</div>
        <div class="flex flex-col gap-2 text-xs font-mono">
          <div class="bg-gray-900 text-gray-100 rounded-lg px-3 py-2 overflow-x-auto">
            GET /api/{@header.schema_context_name}?pagina=1&por_pagina=25
          </div>
          <div :if={@campo_filtro} class="bg-gray-900 text-gray-100 rounded-lg px-3 py-2 overflow-x-auto">
            GET /api/{@header.schema_context_name}?{@campo_filtro["campo"]}=&lt;valor&gt;
          </div>
        </div>
      </div>

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Forma de la respuesta</div>
        <pre class="bg-gray-900 text-gray-100 rounded-lg px-3 py-2 text-[11px] overflow-x-auto"><code>{@ejemplo_json}</code></pre>
        <p class="text-xs text-gray-500 mt-2">
          Las llaves de <code class="font-mono">data</code>/<code class="font-mono">totales</code> van namespaced (<code class="font-mono">catalogo__campo</code>), nunca solo el nombre del campo —
          evita ambigüedad cuando dos tablas unidas comparten nombre de columna. <code class="font-mono">meta_campos</code> trae esa misma llave en <code class="font-mono">clave</code> para no tener que recalcularla del lado del cliente.
          Solo aparecen ahí las columnas visibles del Get Config, en su mismo orden.
        </p>
      </div>
    </div>
    """
  end

  attr :header, :map, required: true
  attr :socket, :any, required: true

  # Embebido como LiveView hijo (live_render/3), mismo criterio que
  # BcMotorLive para su tab Permisos -- CatalogoPermisosLive ya sabe
  # tratar una Consulta como solo-lectura (~w(leer), ver
  # `catalogo.es_consulta` ahí) y ya muestra el Alcance de Datos de esta
  # Consulta como referencia de solo lectura al de su catalogo_base (ver
  # `catalogo_base_de_consulta/1` en ese módulo) -- nada de eso se
  # duplica acá.
  defp panel_permisos(assigns) do
    ~H"""
    <div id="consulta-panel-permisos">
      {live_render(@socket, MetadataAppWeb.Sysadmin.CatalogoPermisosLive,
        id: "permisos-embebido-#{@header.schema_context_name}",
        session: %{"recurso" => @header.schema_context_name}
      )}
    </div>
    """
  end

  attr :consulta, :map, required: true
  attr :subtab_sql, :string, required: true

  # De solo lectura -- 2 sub-tabs (SQL real / Ecto.Query) sobre la
  # query REPRESENTATIVA (MetaConsultas.query_representativa_con_filtros/1:
  # joins + select de las columnas visibles + los WHERE de Parámetro
  # estándar, ver moduledoc de MetaSchema.Consulta -- SIN alcance de
  # datos ni paginación, que dependen de cada request y no tiene sentido
  # fijar acá). Un campo elegible sin default real configurado todavía
  # usa un valor dummy (ver overrides_dummy/1 en MetaConsultas) solo para
  # que el admin vea la FORMA del WHERE que se va a generar -- 100%
  # informativo, nunca se ejecuta contra la base de verdad.
  defp panel_sql(assigns) do
    query = MetaConsultas.query_representativa_con_filtros(assigns.consulta)
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, MetadataApp.Repo, query)

    sql_texto = if params == [], do: formatear_sql(sql), else: "#{formatear_sql(sql)}\n\n-- params: #{inspect(params)}"

    assigns =
      assigns
      |> assign(:sql_texto, sql_texto)
      |> assign(:ecto_texto, inspect(query, pretty: true, width: 70))

    ~H"""
    <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
      <div class="flex gap-1 mb-3">
        <button :for={{id, etiqueta} <- [{"sql", "SQL"}, {"ecto", "Ecto"}]} type="button" phx-click="cambiar_subtab_sql" phx-value-subtab={id}
          class={[
            "px-3 py-1.5 rounded-lg text-xs font-semibold",
            @subtab_sql == id && "bg-purple-600 text-white",
            @subtab_sql != id && "bg-gray-100 text-gray-600 hover:bg-gray-200"
          ]}>
          {etiqueta}
        </button>
      </div>

      <p class="text-xs text-gray-500 mb-1">
        Joins + columnas visibles + los WHERE de Parámetro estándar — sin alcance de datos ni paginación, que dependen de cada request. De solo lectura.
      </p>
      <p class="text-[11px] text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-1.5 mb-3">
        Un parámetro sin default configurado todavía se muestra con un valor de ejemplo, solo para ver la forma del filtro — nunca pisa un default real ya guardado.
      </p>

      <pre :if={@subtab_sql == "sql"} class="bg-gray-900 text-gray-100 rounded-lg px-4 py-3 text-[12px] leading-relaxed overflow-x-auto"><code>{@sql_texto}</code></pre>
      <pre :if={@subtab_sql == "ecto"} class="bg-gray-900 text-gray-100 rounded-lg px-4 py-3 text-[12px] leading-relaxed overflow-x-auto"><code>{@ecto_texto}</code></pre>
    </div>
    """
  end

  # Formato "de belleza" del SQL crudo que devuelve Ecto.Adapters.SQL.to_sql/3
  # (todo en una sola línea) -- una columna del SELECT por renglón, y un
  # salto de línea antes de cada cláusula top-level (FROM/JOIN/ON/WHERE/
  # ORDER BY/LIMIT/OFFSET), mismo criterio visual que cualquier formateador
  # de SQL. Separar por coma "a lo bruto" es seguro acá porque
  # query_representativa/1 nunca trae funciones con comas adentro
  # (agregaciones/IN) -- si el día de mañana este tab llegara a mostrar una
  # query CON filtros, este separador simple dejaría de alcanzar.
  defp formatear_sql(sql) do
    case String.split(sql, ~r/\bFROM\b/, parts: 2) do
      [select_parte, resto] ->
        columnas =
          select_parte
          |> String.replace_prefix("SELECT ", "")
          |> String.split(",")
          |> Enum.map(&("  " <> String.trim(&1)))
          |> Enum.join(",\n")

        resto_formateado =
          resto
          |> String.trim()
          |> String.replace(~r/\s*\bLEFT OUTER JOIN\b\s*/, "\nLEFT OUTER JOIN ")
          |> String.replace(~r/\s*\bINNER JOIN\b\s*/, "\nINNER JOIN ")
          |> String.replace(~r/\s+\bON\b\s+/, "\n  ON ")
          |> String.replace(~r/\s+\bWHERE\b\s+/, "\nWHERE ")
          |> String.replace(~r/\s+\bGROUP BY\b\s+/, "\nGROUP BY ")
          |> String.replace(~r/\s+\bORDER BY\b\s+/, "\nORDER BY ")
          |> String.replace(~r/\s+\bLIMIT\b\s+/, "\nLIMIT ")
          |> String.replace(~r/\s+\bOFFSET\b\s+/, "\nOFFSET ")

        "SELECT\n#{columnas}\nFROM #{resto_formateado}"

      [unico] ->
        unico
    end
  end
end
