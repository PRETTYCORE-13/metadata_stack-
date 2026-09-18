defmodule MetadataAppWeb.Sysadmin.EndpointsLive do
  # SPEC-SYS-1009202602 -- sección propia "Endpoints" (agregada
  # 2026-09-14, a pedido explícito: "no quiero que dependa de una
  # consulta, algo como sección endpoint donde pueda elegir el catálogo
  # y crear su endpoint"). Reemplaza los dos caminos anteriores (el
  # atajo "+ Endpoint" de BcListLive y la pestaña "Endpoint API" de
  # ConsultaEditorLive, ambos retirados) -- esta es la ÚNICA puerta de
  # entrada, la Consulta interna que sostiene cada endpoint se crea de
  # forma transparente, el admin nunca la ve como tal.
  #
  # 3 vistas por `@live_action`:
  #   :index  -- lista todos los endpoints (ConsultaEndpoints.listar_todos/0).
  #   :nuevo  -- elige catálogo base + tabla detalle opcional (unión
  #             autodetectada vía MetaConsultas.detectar_union/2 -- NO es
  #             el armador multi-tabla completo de "Nueva consulta" en BC
  #             List, a propósito, ver requirements.md R47). Crea la
  #             Consulta interna + un ConsultaEndpoint en borrador con
  #             valores por defecto de una, para que aparezca en :index
  #             de inmediato (evita el mismo problema de "endpoints
  #             fantasma" que motivó agregar Eliminar -- ver
  #             ConsultaEndpoints.eliminar/1).
  #   :editar -- panel completo: Campos (marcar Visible/Parámetro sin
  #             salir de acá) + Configuración + Probar + Publicación +
  #             Credenciales + Documentación. Ruteada por el NOMBRE de la
  #             Consulta interna (`schema_context_name` del Header
  #             oculto), no por el id del ConsultaEndpoint -- mismo
  #             criterio que ya usaba ConsultaEditorLive, el endpoint en
  #             sí puede no existir todavía (recién nace al primer
  #             Guardar) aunque en la práctica :nuevo ya lo deja creado.
  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  # Recurso PROPIO desde 2026-09-17 (a pedido explícito -- "en esta
  # pantalla también debe estar Endpoint para permisos", viendo la
  # pestaña Sysadmin sin un switch dedicado) -- antes compartía
  # "sysadmin_bc"/"editar" con el resto de Business Process Builder,
  # ver migración 20260917180000 para la migración de grants existentes.
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_endpoints", "leer"}}

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaConsultas
  alias MetadataApp.ConsultaEndpoints
  alias MetadataApp.FiltrosDefault
  alias MetadataAppWeb.AdminNav

  import MetadataAppWeb.ParametrosCatalogoComponents,
    only: [celdas_parametro: 1, toggle_es_parametro: 1, identificador: 1]

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
    %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"},
    %{tipo: :pagina, id: "sesiones_movil", label: "Sesiones móviles", nav: "/sysadmin/sesiones-movil"},
    %{tipo: :pagina, id: "endpoints", label: "Endpoints", nav: "/sysadmin/endpoints"}
  ]

  @prefijo_ruta_endpoint "/api/consultas/"

  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:current_page, "endpoints")
      |> assign(:menu_items, AdminNav.filtrar_menu(@menu))
      |> assign(:sidebar_open, false)
      |> assign(:show_programacion_children, false)
      |> assign(:show_clientes_children, false)
      |> assign(:show_prettycore_children, false)
      |> assign(:prefijo, @prefijo_ruta_endpoint)

    {:ok, cargar(socket, socket.assigns.live_action, params)}
  end

  defp cargar(socket, :index, _params) do
    assign(socket, :endpoints, ConsultaEndpoints.listar_todos())
  end

  defp cargar(socket, :nuevo, _params) do
    socket
    |> assign(:catalogos, catalogos_elegibles())
    |> assign(:catalogo_base, nil)
    |> assign(:catalogo_detalle, nil)
    |> assign(:preview_union, nil)
    |> assign(:error_nuevo, nil)
  end

  defp cargar(socket, :editar, %{"nombre" => nombre}) do
    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      %{schema_context_type: 3} = header ->
        consulta = MetaConsultas.obtener_por_header_id(header.id)
        campos = Enum.sort_by(consulta.campos, &Map.get(&1, "orden", 0))
        detalles_por_catalogo = MetaSchemaContext.listar_detalles_de_varios(MetaConsultas.catalogos_presentes(consulta))

        socket
        |> assign(:header, header)
        |> assign(:consulta, consulta)
        |> assign(:campos, campos)
        |> assign(:multi_tabla?, consulta.joins != [])
        |> assign(:detalles_por_catalogo, detalles_por_catalogo)
        |> assign(:modos_fecha_rango, FiltrosDefault.modos_fecha_rango())
        |> assign(:modos_fecha_simple, FiltrosDefault.modos_fecha_simple())
        |> assign(:catalogos_referenciables, MetaSchemaContext.listar_catalogos_referenciables())
        |> asignar_endpoint_y_credenciales(consulta)
        |> assign(:credencial_key_temporal, nil)
        |> assign(:modal_nueva_credencial_abierto, false)
        |> assign(:endpoint_resultado_prueba, nil)
        |> assign(:endpoint_error_prueba, nil)
        |> assign(:parametros_elegibles_endpoint, parametros_elegibles_endpoint(consulta))
        |> assign(:campos_visibles_endpoint, campos_visibles_endpoint(consulta))
        |> assign(:campos_reales_alta, campos_reales_alta(consulta.catalogo_base))
        |> assign(:catalogos_detalle_alta, catalogos_detalle_alta(consulta.catalogo_base))
        |> assign(:bpb_habilitado, Application.get_env(:metadata_app, :bpb_habilitado, false))
        |> assign(:sistemas_disponibles, sistemas_disponibles())
        |> assign(:ambiente_sistema, nil)
        |> assign(:ambiente_procesando?, false)
        |> assign(:ambiente_error, nil)

      _otro ->
        socket
        |> put_flash(:error, "Ese endpoint no existe.")
        |> push_navigate(to: ~p"/sysadmin/endpoints")
    end
  end

  defp asignar_endpoint_y_credenciales(socket, consulta) do
    endpoint = ConsultaEndpoints.obtener_por_consulta(consulta.id)
    credenciales = if endpoint, do: ConsultaEndpoints.listar_credenciales(endpoint.id), else: []

    socket
    |> assign(:endpoint, endpoint)
    |> assign(:credenciales, credenciales)
  end

  # Solo catálogos reales (Header type 1) -- a diferencia de
  # MetaSchemaContext.listar_catalogos_referenciables/0 (pensada para un
  # <select> de "a qué apunta una referencia"), acá se descartan los
  # pseudo-catálogos "(sistema)" que agrega esa función: no tienen un
  # Header real detrás, MetaConsultas.crear/2 necesita uno.
  defp catalogos_elegibles do
    MetaSchemaContext.listar_catalogos_referenciables()
    |> Enum.reject(&String.ends_with?(&1.etiqueta, "(sistema)"))
  end

  defp etiqueta_catalogo(catalogos, nombre) do
    case Enum.find(catalogos, &(&1.nombre == nombre)) do
      nil -> nombre
      c -> c.etiqueta
    end
  end

  defp parametros_elegibles_endpoint(consulta) do
    (MetaConsultas.campos_elegibles_fecha(consulta) ++
       MetaConsultas.campos_elegibles_string(consulta) ++
       MetaConsultas.campos_elegibles_numerico(consulta))
    |> Enum.map(fn campo -> Map.put(campo, "clave", campo |> MetaConsultas.clave_campo() |> to_string()) end)
  end

  defp campos_visibles_endpoint(consulta) do
    consulta.campos
    |> Enum.filter(&(&1["visible"] == true))
    |> Enum.map(fn campo -> Map.put(campo, "clave", campo |> MetaConsultas.clave_campo() |> to_string()) end)
  end

  # R54-R58 -- campos REALES del catálogo base (no de la Consulta, que
  # es un subconjunto/namespace distinto) elegibles para "Alta de
  # registros" -- el admin whitelistea cuáles puede mandar el caller.
  # Bug real (2026-09-17): "fecha_registro" salía como opción
  # seleccionable acá igual que cualquier campo de negocio, pero
  # `MetaCatalogoGenerico` la excluye a propósito del cast del
  # changeset (mismo criterio que `estado_id` -- se auto-estampa
  # siempre, nadie la pisa por fuera) -- habilitarla en `campos_alta`
  # no hacía nada útil, y de paso rompía la validación de R65
  # (`body_sin_coincidencias`): como el caller sí mandaba esa clave
  # (aunque el resto de nombres estuvieran mal), `Map.take` daba un
  # mapa "no vacío" y la validación nunca se disparaba, aunque los
  # campos reales de negocio quedaran todos en NULL igual. Mismo
  # criterio de exclusión que ya usa `CatalogoGenerador.generar/1`
  # para "id"/"fecha_registro" al armar la migración física.
  defp campos_reales_alta(catalogo_base) do
    catalogo_base
    |> MetaSchemaContext.listar_detalles()
    |> Enum.reject(&(&1.schema_context_field in ["id", "fecha_registro"]))
    |> Enum.map(fn detalle ->
      props = detalle.schema_context_properties || %{}

      %{
        clave: detalle.schema_context_field,
        tipo: props["tipo"] || "string",
        # Bug real (2026-09-14): un catálogo real generado desde BC List
        # guarda esto como "opcional" (invertido), NUNCA "obligatorio" --
        # esa otra clave solo existe en dependencias de default
        # (MetaSchemaContext.aplicar_defaults_dependientes/2), un
        # concepto distinto. Sin la clave (ej. "fecha_registro", campo
        # de framework no editable) se asume no-obligatorio.
        obligatorio: props["opcional"] == false,
        etiqueta: props["etiqueta"] || detalle.schema_context_field
      }
    end)
  end

  # R59-R61 -- catálogos detalle REALES de catalogo_base (si es un
  # maestro) + sus campos reales, para que el admin pueda whitelistear
  # también los renglones que el alta crea en el mismo ciclo atómico.
  defp catalogos_detalle_alta(catalogo_base) do
    case MetaSchemaContext.obtener_header_por_nombre(catalogo_base) do
      nil ->
        []

      header ->
        header.id
        |> MetaSchemaContext.listar_catalogos_detalle()
        |> Enum.map(fn detalle_header ->
          %{
            nombre: detalle_header.schema_context_name,
            etiqueta: detalle_header.schema_context_label,
            campos: campos_reales_alta(detalle_header.schema_context_name)
          }
        end)
    end
  end

  defp nil_si_vacio(""), do: nil
  defp nil_si_vacio(valor), do: valor

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "endpoints")
  end

  # --- :index -------------------------------------------------------------

  def handle_event("eliminar_endpoint", %{"nombre" => nombre}, socket) do
    caso =
      Enum.find(socket.assigns.endpoints, fn e -> e.consulta.header.schema_context_name == nombre end)

    case caso && ConsultaEndpoints.eliminar(caso) do
      :ok -> {:noreply, assign(socket, :endpoints, ConsultaEndpoints.listar_todos())}
      _otro -> {:noreply, put_flash(socket, :error, "No se pudo eliminar el endpoint.")}
    end
  end

  # --- :nuevo ---------------------------------------------------------------

  def handle_event("validar_seleccion_nuevo", params, socket) do
    catalogo_base = nil_si_vacio(params["catalogo_base"])
    catalogo_detalle = nil_si_vacio(params["catalogo_detalle"])

    preview =
      case {catalogo_base, catalogo_detalle} do
        {nil, _} ->
          nil

        {_base, nil} ->
          nil

        {base, detalle} ->
          case MetaConsultas.detectar_union([base], detalle) do
            {:ok, _union} -> {:ok, MetaConsultas.maestro_de_detalle(detalle)}
            :sin_union -> :sin_union
          end
      end

    {:noreply,
     socket
     |> assign(:catalogo_base, catalogo_base)
     |> assign(:catalogo_detalle, catalogo_detalle)
     |> assign(:preview_union, preview)
     |> assign(:error_nuevo, nil)}
  end

  def handle_event("crear_endpoint", %{"catalogo_base" => catalogo_base} = params, socket) do
    catalogo_base = nil_si_vacio(catalogo_base)
    catalogo_detalle = nil_si_vacio(params["catalogo_detalle"])

    resultado =
      with base when not is_nil(base) <- catalogo_base,
           {:ok, union} <- resolver_union(base, catalogo_detalle),
           label_base <- etiqueta_catalogo(socket.assigns.catalogos, base),
           sufijo <- System.unique_integer([:positive]),
           nombre <- "endpoint_#{base}_#{sufijo}",
           header_attrs <- %{
             "schema_context_name" => nombre,
             "schema_context_label" => "Endpoint — #{label_base}",
             "schema_context_nav" => "/#{nombre}",
             "schema_visible" => false,
             "schema_context_type" => 3,
             "detalles" => []
           },
           {:ok, {header, _detalles}} <- MetaSchemaContext.crear_header_con_detalles(header_attrs),
           {:ok, consulta} <- MetaConsultas.crear(header, base),
           {:ok, consulta} <- agregar_detalle_si_corresponde(consulta, catalogo_detalle, union),
           endpoint_attrs <- %{
             "nombre" => "Endpoint — #{label_base}",
             "metodo" => "get",
             "ruta" => String.replace(nombre, "_", "-"),
             "empresa_id" => socket.assigns.current_scope.empresa_activa.id,
             "parametros" => []
           },
           {:ok, _endpoint} <- ConsultaEndpoints.crear_o_actualizar(consulta, endpoint_attrs) do
        {:ok, nombre}
      end

    case resultado do
      {:ok, nombre} ->
        {:noreply, push_navigate(socket, to: ~p"/sysadmin/endpoints/#{nombre}")}

      nil ->
        {:noreply, assign(socket, :error_nuevo, "Elegí un catálogo base.")}

      {:error, :sin_union} ->
        {:noreply,
         assign(
           socket,
           :error_nuevo,
           "No se pudo detectar automáticamente la relación entre esas dos tablas -- elegí otra tabla de detalle o dejalo en \"Ninguna\"."
         )}

      {:error, _otro} ->
        {:noreply, assign(socket, :error_nuevo, "No se pudo crear el endpoint.")}
    end
  end

  defp resolver_union(_catalogo_base, nil), do: {:ok, nil}

  defp resolver_union(catalogo_base, catalogo_detalle) do
    case MetaConsultas.detectar_union([catalogo_base], catalogo_detalle) do
      {:ok, union} -> {:ok, union}
      :sin_union -> {:error, :sin_union}
    end
  end

  defp agregar_detalle_si_corresponde(consulta, nil, _union), do: {:ok, consulta}

  defp agregar_detalle_si_corresponde(consulta, catalogo_detalle, union) do
    MetaConsultas.agregar_tabla_manual(
      consulta,
      catalogo_detalle,
      union["campo_en_nuevo"],
      union["catalogo_destino"],
      union["campo_en_destino"]
    )
  end

  # --- :editar -- Campos (Visible/Parámetro, sin salir de esta sección) ----
  # Mismos handlers/eventos que ya usaba el Get Config de ConsultaEditorLive
  # (ver MetadataAppWeb.ParametrosCatalogoComponents, que fija esos nombres
  # de evento) -- acá SIN reordenamiento por drag-and-drop ni Campos de
  # control/Orden de resultados (esos siguen siendo exclusivos de Get
  # Config en BC List, no hacen falta para configurar un endpoint).

  def handle_event("guardar_columnas", params, socket) do
    visibles = params |> Map.get("visibles", []) |> List.wrap() |> MapSet.new()
    campos = Enum.map(socket.assigns.campos, fn campo -> Map.put(campo, "visible", identificador(campo) in visibles) end)
    guardar_campos(socket, campos, "Columnas actualizadas.")
  end

  def handle_event("cambiar_es_parametro", %{"campo" => id}, socket) do
    campos =
      mapear_campo(socket, id, fn campo ->
        if campo["visible"] == true or campo["es_parametro"] == true do
          campo
          |> Map.put("es_parametro", !campo["es_parametro"])
          |> Map.put("acotado", false)
          |> Map.put("tipo_filtro", nil)
          |> Map.put("origen", nil)
          |> Map.put("catalogo_referenciado", nil)
          |> Map.put("defaults", %{})
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
         |> assign(:parametros_elegibles_endpoint, parametros_elegibles_endpoint(consulta))
         |> assign(:campos_visibles_endpoint, campos_visibles_endpoint(consulta))
         |> put_flash(:info, mensaje_ok)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo guardar: #{inspect(changeset.errors)}")}
    end
  end

  # --- :editar -- Configuración/Probar/Publicación -------------------------

  def handle_event("guardar_endpoint", params, socket) do
    activos = Map.get(params, "parametros_activos", [])
    obligatorios = params |> Map.get("obligatorios", []) |> MapSet.new()
    descripciones = Map.get(params, "descripciones", %{})

    parametros =
      Enum.map(activos, fn campo ->
        %{"campo" => campo, "obligatorio" => MapSet.member?(obligatorios, campo), "descripcion" => Map.get(descripciones, campo, "")}
      end)

    attrs = %{
      "nombre" => params["nombre"],
      "metodo" => params["metodo"],
      "ruta" => params["ruta"],
      "descripcion" => params["descripcion"],
      "empresa_id" => socket.assigns.current_scope.empresa_activa.id,
      "parametros" => parametros
    }

    case ConsultaEndpoints.crear_o_actualizar(socket.assigns.consulta, attrs) do
      {:ok, endpoint} ->
        {:noreply, socket |> assign(:endpoint, endpoint) |> put_flash(:info, "Endpoint guardado.")}

      {:error, changeset} ->
        mensaje = changeset |> mensajes_de_error() |> Enum.join("; ")
        {:noreply, put_flash(socket, :error, "No se pudo guardar el endpoint: #{mensaje}")}
    end
  end

  defp mensajes_de_error(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(value)) end)
    end)
    |> Enum.flat_map(fn {_campo, mensajes} -> mensajes end)
  end

  def handle_event("publicar_endpoint", _params, socket) do
    case ConsultaEndpoints.publicar(socket.assigns.endpoint) do
      {:ok, endpoint} -> {:noreply, assign(socket, :endpoint, endpoint)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "No se pudo publicar el endpoint.")}
    end
  end

  def handle_event("despublicar_endpoint", _params, socket) do
    {:ok, endpoint} = ConsultaEndpoints.despublicar(socket.assigns.endpoint)
    {:noreply, assign(socket, :endpoint, endpoint)}
  end

  # --- Publicar/despublicar a un ambiente, sin terminal (SPEC-SYS-1009202602,
  # design.md §15, R73-R75) --------------------------------------------------

  def handle_event("elegir_ambiente", %{"sistema" => sistema}, socket) do
    {:noreply, assign(socket, :ambiente_sistema, if(sistema == "", do: nil, else: sistema))}
  end

  # Defensa en profundidad -- el botón ya queda deshabilitado sin
  # ambiente elegido, mismo criterio que BcListLive.
  def handle_event("publicar_a_ambiente", _params, %{assigns: %{ambiente_sistema: nil}} = socket), do: {:noreply, socket}

  def handle_event("publicar_a_ambiente", _params, socket) do
    %{endpoint: endpoint, ambiente_sistema: sistema} = socket.assigns

    socket =
      socket
      |> assign(:ambiente_procesando?, true)
      |> assign(:ambiente_error, nil)
      |> start_async(:ambiente_publicar, fn -> ConsultaEndpoints.publicar_a_ambiente(endpoint, sistema) end)

    {:noreply, socket}
  end

  def handle_event("despublicar_de_ambiente", _params, %{assigns: %{ambiente_sistema: nil}} = socket), do: {:noreply, socket}

  def handle_event("despublicar_de_ambiente", _params, socket) do
    %{endpoint: endpoint, ambiente_sistema: sistema} = socket.assigns

    socket =
      socket
      |> assign(:ambiente_procesando?, true)
      |> assign(:ambiente_error, nil)
      |> start_async(:ambiente_despublicar, fn -> ConsultaEndpoints.despublicar_de_ambiente(endpoint, sistema) end)

    {:noreply, socket}
  end

  def handle_async(:ambiente_publicar, {:ok, {:ok, _salida}}, socket) do
    {:noreply,
     socket
     |> assign(:ambiente_procesando?, false)
     |> put_flash(
       :info,
       "Publicado -- va camino a \"#{socket.assigns.ambiente_sistema}\". Seguí el progreso con \"gh run watch\" o \"gh run list\"."
     )}
  end

  def handle_async(:ambiente_despublicar, {:ok, {:ok, _salida}}, socket) do
    {:noreply,
     socket
     |> assign(:ambiente_procesando?, false)
     |> put_flash(
       :info,
       "Quitado de \"#{socket.assigns.ambiente_sistema}\" -- el endpoint sigue publicado local. Seguí el progreso con \"gh run watch\"."
     )}
  end

  def handle_async(nombre, {:ok, {:error, mensaje}}, socket) when nombre in [:ambiente_publicar, :ambiente_despublicar] do
    {:noreply, socket |> assign(:ambiente_procesando?, false) |> assign(:ambiente_error, mensaje)}
  end

  def handle_async(nombre, {:exit, razon}, socket) when nombre in [:ambiente_publicar, :ambiente_despublicar] do
    {:noreply,
     socket
     |> assign(:ambiente_procesando?, false)
     |> assign(:ambiente_error, "Error inesperado: #{inspect(razon)}")}
  end

  # Mismos sistemas válidos que BcListLive.sistemas_disponibles/0 --
  # clientes reales de priv/sistemas.json + "unstable", nunca
  # "testing"/"stable" directo (esos solo reciben por promoción).
  defp sistemas_disponibles do
    (["unstable"] ++ (MetadataApp.MotorAlta.leer_sistemas() |> Map.keys()))
    |> Enum.sort()
  end

  def handle_event("guardar_alta", params, socket) do
    renglones_alta =
      params
      |> Map.get("renglones_alta", %{})
      |> Enum.map(fn {catalogo, campos} -> %{"catalogo" => catalogo, "campos" => List.wrap(campos)} end)

    attrs = %{
      "permite_alta" => params["permite_alta"] == "true",
      "campos_alta" => Map.get(params, "campos_alta", []),
      "renglones_alta" => renglones_alta
    }

    case ConsultaEndpoints.crear_o_actualizar(socket.assigns.consulta, attrs) do
      {:ok, endpoint} ->
        {:noreply, socket |> assign(:endpoint, endpoint) |> put_flash(:info, "Configuración de alta guardada.")}

      {:error, changeset} ->
        mensaje = changeset |> mensajes_de_error() |> Enum.join("; ")
        {:noreply, put_flash(socket, :error, "No se pudo guardar: #{mensaje}")}
    end
  end

  def handle_event("eliminar_endpoint_actual", _params, socket) do
    :ok = ConsultaEndpoints.eliminar(socket.assigns.endpoint)
    {:noreply, push_navigate(socket, to: ~p"/sysadmin/endpoints")}
  end

  def handle_event("probar_endpoint", %{"valores_prueba" => valores}, socket) do
    case ConsultaEndpoints.construir_overrides(socket.assigns.consulta, socket.assigns.endpoint, valores) do
      {:ok, overrides} ->
        resultado = ConsultaEndpoints.probar(socket.assigns.consulta, socket.assigns.current_scope, overrides)
        {:noreply, socket |> assign(:endpoint_resultado_prueba, resultado) |> assign(:endpoint_error_prueba, nil)}

      {:error, {:parametros_faltantes, claves}} ->
        mensaje = "Faltan parámetros obligatorios: #{Enum.join(claves, ", ")}"
        {:noreply, socket |> assign(:endpoint_error_prueba, mensaje) |> assign(:endpoint_resultado_prueba, nil)}
    end
  end

  # --- :editar -- Credenciales (R19.1, R42-R46) -----------------------------

  def handle_event("abrir_modal_nueva_credencial", _params, socket) do
    {:noreply, assign(socket, :modal_nueva_credencial_abierto, true)}
  end

  def handle_event("cerrar_modal_nueva_credencial", _params, socket) do
    {:noreply, assign(socket, :modal_nueva_credencial_abierto, false)}
  end

  def handle_event("crear_credencial", params, socket) do
    campos_permitidos = Map.get(params, "campos_permitidos", [])
    attrs = %{"nombre" => params["nombre"], "campos_permitidos" => campos_permitidos}

    case ConsultaEndpoints.crear_credencial(socket.assigns.endpoint, socket.assigns.consulta, attrs) do
      {:ok, _credencial, key} ->
        {:noreply,
         socket
         |> assign(:credenciales, ConsultaEndpoints.listar_credenciales(socket.assigns.endpoint.id))
         |> assign(:credencial_key_temporal, key)
         |> assign(:modal_nueva_credencial_abierto, false)}

      {:error, changeset} ->
        mensaje = changeset |> mensajes_de_error() |> Enum.join("; ")
        {:noreply, put_flash(socket, :error, "No se pudo crear la credencial: #{mensaje}")}
    end
  end

  def handle_event("regenerar_api_key_credencial", %{"id" => id}, socket) do
    credencial = Enum.find(socket.assigns.credenciales, &(&1.id == String.to_integer(id)))
    {:ok, _regenerada, key} = ConsultaEndpoints.regenerar_api_key_credencial(credencial)

    {:noreply,
     socket
     |> assign(:credenciales, ConsultaEndpoints.listar_credenciales(socket.assigns.endpoint.id))
     |> assign(:credencial_key_temporal, key)}
  end

  def handle_event("revocar_credencial", %{"id" => id}, socket) do
    credencial = Enum.find(socket.assigns.credenciales, &(&1.id == String.to_integer(id)))
    {:ok, _revocada} = ConsultaEndpoints.revocar_credencial(credencial)
    {:noreply, assign(socket, :credenciales, ConsultaEndpoints.listar_credenciales(socket.assigns.endpoint.id))}
  end

  # --- render ---------------------------------------------------------------

  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto p-6 text-xs font-sans">
      <.vista_index :if={@live_action == :index} endpoints={@endpoints} />
      <.vista_nuevo :if={@live_action == :nuevo} catalogos={@catalogos} catalogo_base={@catalogo_base}
        catalogo_detalle={@catalogo_detalle} preview_union={@preview_union} error_nuevo={@error_nuevo} />
      <.vista_editar :if={@live_action == :editar} header={@header} consulta={@consulta} campos={@campos}
        multi_tabla?={@multi_tabla?} detalles_por_catalogo={@detalles_por_catalogo} modos_fecha_rango={@modos_fecha_rango}
        modos_fecha_simple={@modos_fecha_simple} catalogos_referenciables={@catalogos_referenciables}
        endpoint={@endpoint} credenciales={@credenciales} credencial_key_temporal={@credencial_key_temporal}
        modal_nueva_credencial_abierto={@modal_nueva_credencial_abierto} parametros_elegibles={@parametros_elegibles_endpoint}
        campos_visibles={@campos_visibles_endpoint} campos_reales_alta={@campos_reales_alta} catalogos_detalle_alta={@catalogos_detalle_alta}
        endpoint_resultado_prueba={@endpoint_resultado_prueba}
        endpoint_error_prueba={@endpoint_error_prueba} prefijo={@prefijo} />
    </div>
    """
  end

  attr :endpoints, :list, required: true

  defp vista_index(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-4">
      <h1 class="text-lg font-bold text-gray-900 flex items-center gap-2">
        <span class="material-symbols-outlined text-purple-600">api</span>
        Endpoints
      </h1>
      <.link navigate={~p"/sysadmin/endpoints/nuevo"} class="px-4 py-2 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
        + Nuevo endpoint
      </.link>
    </div>

    <div class="bg-white border border-gray-200 rounded-2xl shadow-sm overflow-x-auto">
      <table class="min-w-full divide-y divide-gray-200 text-xs">
        <thead class="bg-gray-50">
          <tr>
            <th class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">Nombre</th>
            <th class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">Catálogo(s)</th>
            <th class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">Ruta</th>
            <th class="px-3 py-2 text-left font-semibold text-gray-500 uppercase tracking-wide">Estado</th>
            <th class="px-3 py-2"></th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-100">
          <tr :for={endpoint <- @endpoints}>
            <td class="px-3 py-2.5 font-semibold text-gray-800">{endpoint.nombre}</td>
            <td class="px-3 py-2.5 text-gray-500">{Enum.join(MetaConsultas.catalogos_presentes(endpoint.consulta), " + ")}</td>
            <td class="px-3 py-2.5 font-mono text-gray-500">
              <span class="uppercase text-[10px] font-bold text-purple-600 mr-1">{endpoint.metodo}</span>{endpoint.ruta}
            </td>
            <td class="px-3 py-2.5">
              <span class={[
                "text-[10px] font-bold px-1.5 py-0.5 rounded",
                endpoint.estado == "publicado" && "bg-emerald-100 text-emerald-700",
                endpoint.estado != "publicado" && "bg-gray-100 text-gray-500"
              ]}>
                {if endpoint.estado == "publicado", do: "PUBLICADO", else: "BORRADOR"}
              </span>
            </td>
            <td class="px-3 py-2.5 text-right">
              <.link navigate={~p"/sysadmin/endpoints/#{endpoint.consulta.header.schema_context_name}"}
                class="text-blue-600 hover:text-blue-800 font-semibold mr-3">
                Configurar
              </.link>
              <button type="button" phx-click="eliminar_endpoint" phx-value-nombre={endpoint.consulta.header.schema_context_name}
                data-confirm={"Se borra el endpoint '#{endpoint.nombre}' y todas sus credenciales, para siempre. ¿Eliminar?"}
                class="text-red-600 hover:text-red-800 font-semibold">
                Eliminar
              </button>
            </td>
          </tr>
          <tr :if={@endpoints == []}>
            <td colspan="5" class="px-3 py-8 text-center text-gray-400">Todavía no creaste ningún endpoint.</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :catalogos, :list, required: true
  attr :catalogo_base, :string, default: nil
  attr :catalogo_detalle, :string, default: nil
  attr :preview_union, :any, default: nil
  attr :error_nuevo, :string, default: nil

  defp vista_nuevo(assigns) do
    detalles_disponibles = Enum.reject(assigns.catalogos, &(&1.nombre == assigns.catalogo_base))
    assigns = assign(assigns, :detalles_disponibles, detalles_disponibles)

    ~H"""
    <div class="flex items-center gap-2 mb-4">
      <.link navigate={~p"/sysadmin/endpoints"} class="w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700">
        <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
      </.link>
      <h1 class="text-lg font-bold text-gray-900">Nuevo endpoint</h1>
    </div>

    <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-5 max-w-xl">
      <form phx-change="validar_seleccion_nuevo" phx-submit="crear_endpoint" class="flex flex-col gap-4">
        <label class="flex flex-col gap-1 text-xs font-semibold text-gray-600">
          Catálogo base
          <select name="catalogo_base" class="border border-gray-300 rounded-lg px-2 py-1.5 text-gray-900 font-normal">
            <option value="">— elegir catálogo —</option>
            <option :for={c <- @catalogos} value={c.nombre} selected={c.nombre == @catalogo_base}>{c.etiqueta}</option>
          </select>
        </label>

        <label :if={@catalogo_base} class="flex flex-col gap-1 text-xs font-semibold text-gray-600">
          Tabla detalle (opcional)
          <select name="catalogo_detalle" class="border border-gray-300 rounded-lg px-2 py-1.5 text-gray-900 font-normal">
            <option value="">Ninguna</option>
            <option :for={c <- @detalles_disponibles} value={c.nombre} selected={c.nombre == @catalogo_detalle}>{c.etiqueta}</option>
          </select>
        </label>

        <p :if={@preview_union == :sin_union} class="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-1.5">
          No se detectó ninguna relación automática entre esas dos tablas.
        </p>
        <p :if={match?({:ok, _}, @preview_union) and elem(@preview_union, 1)} class="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-1.5">
          Detalle de "{elem(@preview_union, 1)}" -- el reporte va a traer varias filas por cada registro del catálogo base.
        </p>
        <p :if={match?({:ok, _}, @preview_union) and !elem(@preview_union, 1)} class="text-xs text-emerald-700 bg-emerald-50 border border-emerald-200 rounded-lg px-3 py-1.5">
          Relación detectada automáticamente.
        </p>
        <p :if={@error_nuevo} class="text-xs text-red-700 bg-red-50 border border-red-200 rounded-lg px-3 py-1.5">
          {@error_nuevo}
        </p>

        <div class="flex justify-end pt-2 border-t border-gray-100">
          <button type="submit" class="px-4 py-2 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
            Crear endpoint
          </button>
        </div>
      </form>
    </div>
    """
  end

  attr :header, :map, required: true
  attr :consulta, :map, required: true
  attr :campos, :list, required: true
  attr :multi_tabla?, :boolean, required: true
  attr :detalles_por_catalogo, :map, required: true
  attr :modos_fecha_rango, :list, required: true
  attr :modos_fecha_simple, :list, required: true
  attr :catalogos_referenciables, :list, required: true
  attr :endpoint, :map, default: nil
  attr :credenciales, :list, required: true
  attr :credencial_key_temporal, :string, default: nil
  attr :modal_nueva_credencial_abierto, :boolean, default: false
  attr :parametros_elegibles, :list, required: true
  attr :campos_visibles, :list, required: true
  attr :campos_reales_alta, :list, required: true
  attr :catalogos_detalle_alta, :list, required: true
  attr :endpoint_resultado_prueba, :map, default: nil
  attr :endpoint_error_prueba, :string, default: nil
  attr :prefijo, :string, required: true

  defp vista_editar(assigns) do
    activos = if assigns.endpoint, do: MapSet.new(assigns.endpoint.parametros, & &1["campo"]), else: MapSet.new()
    obligatorios = if assigns.endpoint, do: MapSet.new(for %{"campo" => c, "obligatorio" => true} <- assigns.endpoint.parametros, do: c), else: MapSet.new()

    assigns =
      assigns
      |> assign(:parametros_activos, activos)
      |> assign(:parametros_obligatorios, obligatorios)
      |> assign(:publicado?, assigns.endpoint && assigns.endpoint.estado == "publicado")

    ~H"""
    <div class="flex items-start justify-between gap-4 mb-4">
      <div class="flex items-start gap-2">
        <.link navigate={~p"/sysadmin/endpoints"} title="Volver al listado de endpoints"
          class="mt-0.5 w-7 h-7 flex items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 shrink-0">
          <span class="material-symbols-outlined" style="font-size: 18px">arrow_back</span>
        </.link>
        <div>
          <h1 class="text-lg font-bold text-gray-900 flex items-center gap-2">
            <span class="material-symbols-outlined text-purple-600">api</span>
            {@header.schema_context_label}
          </h1>
          <p class="mt-0.5 text-gray-500">
            Sobre <strong>{Enum.join(MetaConsultas.catalogos_presentes(@consulta), " + ")}</strong>
          </p>
        </div>
      </div>
      <button :if={@endpoint} type="button" phx-click="eliminar_endpoint_actual"
        data-confirm="Se borra este endpoint y todas sus credenciales, para siempre. ¿Eliminar?"
        class="shrink-0 text-xs font-semibold text-red-600 hover:text-red-800">
        Eliminar endpoint
      </button>
    </div>

    <div class="flex flex-col gap-4">
      <.panel_campos campos={@campos} multi_tabla?={@multi_tabla?} detalles_por_catalogo={@detalles_por_catalogo}
        modos_fecha_rango={@modos_fecha_rango} modos_fecha_simple={@modos_fecha_simple} catalogos_referenciables={@catalogos_referenciables} />

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-3">Configuración del endpoint</div>
        <form phx-submit="guardar_endpoint" class="flex flex-col gap-3">
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <label class="flex flex-col gap-1 text-xs font-semibold text-gray-600">
              Nombre
              <input type="text" name="nombre" value={@endpoint && @endpoint.nombre} required
                class="border border-gray-300 rounded-lg px-2 py-1.5 text-gray-900 font-normal" />
            </label>
            <label class="flex flex-col gap-1 text-xs font-semibold text-gray-600">
              Método
              <select name="metodo" class="border border-gray-300 rounded-lg px-2 py-1.5 text-gray-900 font-normal">
                <option value="get" selected={!@endpoint || @endpoint.metodo == "get"}>GET</option>
                <option value="post" selected={@endpoint && @endpoint.metodo == "post"}>POST</option>
              </select>
            </label>
            <label class="flex flex-col gap-1 text-xs font-semibold text-gray-600">
              Ruta
              <div class="flex items-center border border-gray-300 rounded-lg overflow-hidden">
                <span class="bg-gray-50 text-gray-400 font-mono text-xs px-2 py-1.5 shrink-0">{@prefijo}</span>
                <input type="text" name="ruta" value={@endpoint && @endpoint.ruta} required pattern="[a-z0-9-]+"
                  class="border-0 focus:ring-0 px-2 py-1.5 text-gray-900 font-mono text-xs flex-1 min-w-0" />
              </div>
            </label>
          </div>
          <label class="flex flex-col gap-1 text-xs font-semibold text-gray-600">
            Descripción
            <input type="text" name="descripcion" value={@endpoint && @endpoint.descripcion}
              class="border border-gray-300 rounded-lg px-2 py-1.5 text-gray-900 font-normal" />
          </label>

          <div>
            <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-1.5">
              Parámetros de entrada (de los ya marcados Parámetro en "Campos", arriba)
            </div>
            <div :if={@parametros_elegibles == []} class="text-xs text-gray-400">
              Todavía no marcaste ningún campo como Parámetro.
            </div>
            <table :if={@parametros_elegibles != []} class="min-w-full text-xs">
              <thead>
                <tr class="text-gray-400 uppercase text-[10px]">
                  <th class="text-left py-1 pr-2">Activo</th>
                  <th class="text-left py-1 pr-2">Campo</th>
                  <th class="text-left py-1 pr-2">Tipo</th>
                  <th class="text-left py-1 pr-2">Obligatorio</th>
                  <th class="text-left py-1 pr-2">Descripción</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :for={campo <- @parametros_elegibles}>
                  <td class="py-1 pr-2">
                    <input type="checkbox" name="parametros_activos[]" value={campo["clave"]}
                      checked={MapSet.member?(@parametros_activos, campo["clave"])} />
                  </td>
                  <td class="py-1 pr-2 font-mono text-gray-700">{campo["clave"]}</td>
                  <td class="py-1 pr-2 text-gray-400">{campo["tipo"]}{campo["acotado"] && " (rango)"}</td>
                  <td class="py-1 pr-2">
                    <input type="checkbox" name="obligatorios[]" value={campo["clave"]}
                      checked={MapSet.member?(@parametros_obligatorios, campo["clave"])} />
                  </td>
                  <td class="py-1 pr-2">
                    <input type="text" name={"descripciones[#{campo["clave"]}]"} value={descripcion_actual(@endpoint, campo["clave"])}
                      placeholder="Para qué sirve este parámetro (opcional)"
                      class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-full" />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="flex justify-end pt-2 border-t border-gray-100">
            <button type="submit" class="px-4 py-2 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
              Guardar
            </button>
          </div>
        </form>
      </div>

      <!-- Alta de registros (R54-R58, agregado 2026-09-14, a pedido
           explícito -- "necesito que el post agregue registros"). Solo
           tiene sentido para un endpoint POST -- un GET no tiene body
           para mandar los campos del registro nuevo. Modo EXCLUYENTE con
           la consulta: si @endpoint.permite_alta, el body del POST se
           interpreta como los campos del registro nuevo, nunca como
           filtros de búsqueda (ver ConsultaEndpointController.ejecutar/5). -->
      <div :if={@endpoint && @endpoint.metodo == "post"} class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-1">Alta de registros (el POST inserta filas)</div>
        <p class="text-xs text-gray-500 mb-3">
          Mismas reglas que un alta manual desde la UI (motor de estados, folio/TRN si el catálogo es transaccional).
          Si se activa, el body del POST se toma como los campos del registro nuevo -- deja de aceptar filtros de búsqueda.
        </p>
        <form phx-submit="guardar_alta" class="flex flex-col gap-3">
          <label class="flex items-center gap-2 text-xs font-semibold text-gray-700">
            <input type="hidden" name="permite_alta" value="false" />
            <input type="checkbox" name="permite_alta" value="true" checked={@endpoint.permite_alta} class="accent-purple-600" />
            Permitir que este POST inserte registros
          </label>

          <div :if={@campos_reales_alta != []}>
            <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-1.5">Campos que el caller puede mandar</div>
            <table class="min-w-full text-xs">
              <thead>
                <tr class="text-gray-400 uppercase text-[10px]">
                  <th class="text-left py-1 pr-2">
                    <input type="checkbox" phx-hook="SeleccionarTodosCheckbox" id="seleccionar-todos-campos-alta"
                      data-objetivo="input[name='campos_alta[]']" title="Seleccionar/deseleccionar todos" />
                  </th>
                  <th class="text-left py-1 pr-2">Campo</th>
                  <th class="text-left py-1 pr-2">Tipo</th>
                  <th class="text-left py-1 pr-2">Obligatorio en el catálogo</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :for={campo <- @campos_reales_alta}>
                  <td class="py-1 pr-2">
                    <input type="checkbox" name="campos_alta[]" value={campo.clave} checked={campo.clave in @endpoint.campos_alta} />
                  </td>
                  <td class="py-1 pr-2 font-mono text-gray-700">{campo.clave}</td>
                  <td class="py-1 pr-2 text-gray-400">{campo.tipo}{tipo_hint(campo.tipo)}</td>
                  <td class="py-1 pr-2 text-gray-400">{if campo.obligatorio, do: "Sí", else: "No"}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p :if={@campos_reales_alta == []} class="text-xs text-gray-400">Este catálogo no tiene campos configurados.</p>

          <!-- Renglones (R59-R61) -- solo si catalogo_base es un
               MAESTRO con catálogos detalle reales. El body manda cada
               lista de renglones bajo la clave del catálogo detalle
               (ver ejemplo_alta/3) -- "encabezado_id" lo estampa el
               motor solo, nunca lo manda el caller. -->
          <div :if={@catalogos_detalle_alta != []} class="flex flex-col gap-3 pt-2 border-t border-gray-100">
            <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400">
              Renglones -- crea también los detalles iniciales en el mismo alta
            </div>
            <div :for={detalle <- @catalogos_detalle_alta} class="bg-gray-50 border border-gray-200 rounded-lg p-3">
              <div class="flex items-center gap-1.5 mb-1.5">
                <input type="checkbox" phx-hook="SeleccionarTodosCheckbox" id={"seleccionar-todos-renglon-#{detalle.nombre}"}
                  data-objetivo={"input[name='renglones_alta[#{detalle.nombre}][]']"} title="Seleccionar/deseleccionar todos" />
                <span class="text-xs font-semibold text-gray-700">{detalle.etiqueta} <span class="font-mono text-gray-400">({detalle.nombre})</span></span>
              </div>
              <div :if={detalle.campos == []} class="text-xs text-gray-400">Este catálogo detalle no tiene campos configurados.</div>
              <label :for={campo <- detalle.campos} class="flex items-center gap-1.5 text-xs text-gray-700 py-0.5">
                <input type="checkbox" name={"renglones_alta[#{detalle.nombre}][]"} value={campo.clave}
                  checked={campo.clave in renglon_campos_actuales(@endpoint, detalle.nombre)} />
                <span class="font-mono">{campo.clave}</span>
                <span class="text-gray-400">{campo.tipo}{tipo_hint(campo.tipo)}{campo.obligatorio && " · obligatorio"}</span>
              </label>
            </div>
          </div>

          <div class="flex justify-end pt-2 border-t border-gray-100">
            <button type="submit" class="px-4 py-2 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
              Guardar
            </button>
          </div>
        </form>
      </div>

      <div :if={@endpoint} class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-3">Probar (no requiere estar publicado)</div>
        <form phx-submit="probar_endpoint" class="flex flex-col gap-2">
          <div :for={campo <- @parametros_elegibles} :if={MapSet.member?(@parametros_activos, campo["clave"])} class="flex flex-col sm:flex-row sm:items-center gap-1.5">
            <span class="text-xs font-mono text-gray-600 w-64 shrink-0">{campo["clave"]}{campo["acotado"] && " (desde/hasta)"}</span>
            <input :if={!campo["acotado"]} type="text" name={"valores_prueba[#{campo["clave"]}]"}
              class="border border-gray-300 rounded-lg px-2 py-1 text-xs w-full" />
            <div :if={campo["acotado"]} class="flex gap-1.5 w-full">
              <input type="text" placeholder="desde" name={"valores_prueba[#{campo["clave"]}_desde]"}
                class="border border-gray-300 rounded-lg px-2 py-1 text-xs w-full" />
              <input type="text" placeholder="hasta" name={"valores_prueba[#{campo["clave"]}_hasta]"}
                class="border border-gray-300 rounded-lg px-2 py-1 text-xs w-full" />
            </div>
          </div>
          <div class="flex justify-end">
            <button type="submit" class="px-3 py-1.5 rounded-lg bg-gray-800 text-white text-xs font-semibold hover:bg-gray-900">
              Probar
            </button>
          </div>
        </form>

        <p :if={@endpoint_error_prueba} class="mt-2 text-xs text-red-700 bg-red-50 border border-red-200 rounded-lg px-3 py-1.5">
          {@endpoint_error_prueba}
        </p>
        <div :if={@endpoint_resultado_prueba} class="mt-2">
          <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-1">Respuesta</div>
          <pre class="bg-gray-900 text-gray-100 rounded-lg px-3 py-2 text-[11px] overflow-x-auto">{inspect(@endpoint_resultado_prueba.filas, pretty: true, limit: 20)}</pre>
        </div>
      </div>

      <div :if={@endpoint} class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-3">Publicación</div>

        <div class="flex items-center gap-2 mb-3">
          <span class={[
            "text-[10px] font-bold px-1.5 py-0.5 rounded",
            @publicado? && "bg-emerald-100 text-emerald-700",
            !@publicado? && "bg-gray-100 text-gray-500"
          ]}>
            {if @publicado?, do: "PUBLICADO", else: "BORRADOR"}
          </span>
          <span :if={@publicado?} class="text-[10px] font-bold px-1.5 py-0.5 rounded bg-purple-100 text-purple-700 uppercase">
            {@endpoint.metodo}
          </span>
          <code :if={@publicado?} class="font-mono text-xs bg-gray-100 px-2 py-1 rounded">{@prefijo}{@endpoint.ruta}</code>
        </div>

        <div class="flex gap-2">
          <button :if={!@publicado?} type="button" phx-click="publicar_endpoint"
            class="px-3 py-1.5 rounded-lg bg-emerald-600 text-white text-xs font-semibold hover:bg-emerald-700">
            Publicar
          </button>
          <button :if={@publicado?} type="button" phx-click="despublicar_endpoint"
            class="px-3 py-1.5 rounded-lg bg-gray-200 text-gray-700 text-xs font-semibold hover:bg-gray-300">
            Despublicar
          </button>
        </div>

        <div :if={@bpb_habilitado} class="mt-4 pt-4 border-t border-gray-100">
          <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">
            Ambientes (SPEC-SYS-1009202602, R73-R75)
          </div>

          <div :if={@ambiente_error} class="mb-2 rounded-lg border border-red-200 bg-red-50 text-red-700 text-xs px-2.5 py-1.5">
            {@ambiente_error}
          </div>

          <p :if={@sistemas_disponibles == []} class="text-xs text-gray-400 mb-2">
            No hay ningún sistema de alta todavía (priv/sistemas.json vacío) -- solo "unstable" disponible.
          </p>

          <div class="flex items-center gap-2 flex-wrap">
            <form phx-change="elegir_ambiente">
              <select name="sistema" class="border border-gray-300 rounded-lg text-gray-900 text-xs px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500">
                <option value="" selected={is_nil(@ambiente_sistema)}>Elegí un ambiente…</option>
                <option :for={sistema <- @sistemas_disponibles} value={sistema} selected={@ambiente_sistema == sistema}>
                  {sistema}
                </option>
              </select>
            </form>

            <button type="button" phx-click="publicar_a_ambiente" disabled={is_nil(@ambiente_sistema) or @ambiente_procesando?}
              class="px-3 py-1.5 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700 disabled:opacity-40 disabled:cursor-not-allowed">
              Publicar a ambiente
            </button>
            <button type="button" phx-click="despublicar_de_ambiente" disabled={is_nil(@ambiente_sistema) or @ambiente_procesando?}
              data-confirm="Esto quita el endpoint SOLO de ese ambiente -- local queda igual. ¿Confirmar?"
              class="px-3 py-1.5 rounded-lg bg-gray-200 text-gray-700 text-xs font-semibold hover:bg-gray-300 disabled:opacity-40 disabled:cursor-not-allowed">
              Quitar de ambiente
            </button>

            <span :if={@ambiente_procesando?} class="text-xs text-gray-500 flex items-center gap-1.5">
              <svg class="animate-spin h-3.5 w-3.5 text-purple-600" viewBox="0 0 24 24" fill="none">
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
              </svg>
              Publicando/despublicando (tarda unos segundos por la red)…
            </span>
          </div>
        </div>
      </div>

      <div :if={@endpoint} class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-3">Credenciales</div>

        <div :if={@credencial_key_temporal} class="mb-3 text-xs bg-amber-50 border border-amber-200 rounded-lg px-3 py-2">
          <p class="font-semibold text-amber-800 mb-1">Copiá esta API key ahora — no se va a volver a mostrar completa.</p>
          <code class="font-mono text-[11px] bg-white border border-amber-200 rounded px-2 py-1 block break-all">{@credencial_key_temporal}</code>
        </div>

        <p :if={@credenciales == []} class="text-xs text-gray-400 mb-3">Todavía no hay ninguna credencial creada.</p>

        <div :for={credencial <- @credenciales} class="border border-gray-200 rounded-xl px-3 py-2.5 mb-2">
          <div class="flex items-center justify-between gap-2">
            <div>
              <span class="font-semibold text-sm text-gray-800">{credencial.nombre}</span>
              <span class={[
                "ml-2 text-[10px] font-bold uppercase tracking-wide",
                credencial.estado == "activa" && "text-emerald-600",
                credencial.estado == "revocada" && "text-gray-400"
              ]}>
                {if credencial.estado == "activa", do: "● Activa", else: "Revocada"}
              </span>
              <p class="text-[11px] text-gray-500 mt-0.5">
                Solo lectura · {length(credencial.campos_permitidos)} campo{if length(credencial.campos_permitidos) != 1, do: "s"} ·
                <code class="font-mono">{String.duplicate("•", 16)}{credencial.api_key_sufijo}</code>
              </p>
            </div>
            <div class="flex items-center gap-2 shrink-0">
              <button :if={credencial.estado == "activa"} type="button" phx-click="regenerar_api_key_credencial" phx-value-id={credencial.id}
                data-confirm="La API key anterior deja de funcionar de inmediato. ¿Regenerar?"
                class="text-xs font-semibold text-gray-600 hover:text-gray-900">
                Regenerar
              </button>
              <button :if={credencial.estado == "activa"} type="button" phx-click="revocar_credencial" phx-value-id={credencial.id}
                data-confirm={"La credencial '#{credencial.nombre}' deja de funcionar para siempre. ¿Revocar?"}
                class="text-xs font-semibold text-red-600 hover:text-red-800">
                Revocar
              </button>
            </div>
          </div>
          <details :if={credencial.campos_permitidos != []} class="mt-1.5">
            <summary class="text-[11px] text-purple-700 cursor-pointer select-none">Ver permisos</summary>
            <ul class="mt-1 text-[11px] text-gray-500 font-mono list-disc list-inside">
              <li :for={campo <- credencial.campos_permitidos}>{campo}</li>
            </ul>
          </details>
        </div>

        <button type="button" phx-click="abrir_modal_nueva_credencial"
          class="mt-2 px-3 py-1.5 rounded-lg bg-white border border-gray-300 text-gray-700 text-xs font-semibold hover:bg-gray-50">
          + Nueva credencial
        </button>

        <div :if={@modal_nueva_credencial_abierto} class="fixed inset-0 bg-black/30 flex items-center justify-center z-50">
          <div class="bg-white rounded-2xl shadow-xl p-5 w-full max-w-md max-h-[90vh] overflow-y-auto" phx-click-away="cerrar_modal_nueva_credencial">
            <div class="font-bold text-gray-900 mb-3">Nueva credencial</div>
            <form phx-submit="crear_credencial" class="flex flex-col gap-3">
              <label class="flex flex-col gap-1 text-xs font-semibold text-gray-600">
                Nombre
                <input type="text" name="nombre" placeholder="Sistema de tienda" required
                  class="border border-gray-300 rounded-lg px-2 py-1.5 text-gray-900 font-normal" />
              </label>
              <div>
                <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-1.5">Permisos</div>
                <label class="flex items-center gap-1.5 text-xs text-gray-700 mb-2">
                  <input type="checkbox" checked disabled /> Lectura
                </label>
                <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-1.5">Campos que puede exponer</div>
                <div :if={@campos_visibles == []} class="text-xs text-gray-400">Todavía no marcaste ningún campo como visible.</div>
                <!-- Bug real (2026-09-15): sin este límite/scroll propio, un
                     catálogo con muchos campos (ej. "historico", 38) empuja
                     el modal entero fuera de la pantalla, dejando el botón
                     "Crear credencial" inalcanzable -- el modal en sí no
                     tenía scroll, solo la página de atrás. -->
                <div :if={@campos_visibles != []} class="max-h-56 overflow-y-auto border border-gray-100 rounded-lg px-2 py-1">
                  <label class="flex items-center gap-1.5 text-xs font-semibold text-gray-600 py-0.5 border-b border-gray-100 mb-0.5 sticky top-0 bg-white">
                    <input type="checkbox" phx-hook="SeleccionarTodosCheckbox" id="seleccionar-todos-campos-permitidos"
                      data-objetivo="input[name='campos_permitidos[]']" /> Seleccionar todos
                  </label>
                  <label :for={campo <- @campos_visibles} class="flex items-center gap-1.5 text-xs text-gray-700 py-0.5">
                    <input type="checkbox" name="campos_permitidos[]" value={campo["clave"]} /> {campo["etiqueta"] || campo["clave"]}
                  </label>
                </div>
              </div>
              <div class="flex justify-end gap-2 pt-2 border-t border-gray-100">
                <button type="button" phx-click="cerrar_modal_nueva_credencial"
                  class="px-3 py-1.5 rounded-lg bg-white border border-gray-300 text-gray-700 text-xs font-semibold hover:bg-gray-50">
                  Cancelar
                </button>
                <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700">
                  Crear credencial
                </button>
              </div>
            </form>
          </div>
        </div>
      </div>

      <div :if={@endpoint} class="bg-white border border-gray-200 rounded-2xl shadow-sm p-4">
        <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-2">Documentación</div>
        <p class="text-xs text-gray-500 mb-4">
          Autenticación: encabezado <code class="font-mono">Authorization: Bearer &lt;api_key&gt;</code>. Nunca por query string.
          Paginación: <code class="font-mono">pagina</code>/<code class="font-mono">por_pagina</code> (default 50, máximo 200).
        </p>

        <div :if={!@endpoint.permite_alta} class="grid grid-cols-1 lg:grid-cols-[1fr_340px] gap-6 items-start">
          <div>
            <div :if={@endpoint.parametros == []} class="text-xs text-gray-400">Este endpoint no recibe parámetros.</div>
            <div :for={p <- @endpoint.parametros} class="py-3 border-b border-gray-100 last:border-0">
              <div class="flex items-center gap-2 flex-wrap mb-1">
                <span class="font-mono text-sm font-semibold text-blue-600">{p["campo"]}</span>
                <span class="text-[10px] font-semibold px-1.5 py-0.5 rounded bg-gray-100 text-gray-500">
                  {campo_tipo(@parametros_elegibles, p["campo"])}
                </span>
                <span class={[
                  "text-[10px] font-bold uppercase tracking-wide px-1.5 py-0.5 rounded",
                  p["obligatorio"] && "bg-amber-100 text-amber-700",
                  !p["obligatorio"] && "bg-gray-100 text-gray-400"
                ]}>
                  {if p["obligatorio"], do: "Obligatorio", else: "Opcional"}
                </span>
              </div>
              <p class="text-sm text-gray-700 font-medium">{etiqueta_parametro(@parametros_elegibles, p["campo"])}</p>
              <p :if={p["descripcion"] not in [nil, ""]} class="text-xs text-gray-500 mt-0.5">{p["descripcion"]}</p>
            </div>
          </div>

          <div class="lg:sticky lg:top-4 flex flex-col gap-3">
            <div>
              <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-1">Ejemplo de solicitud</div>
              <pre class="bg-gray-900 text-gray-100 rounded-lg px-3 py-2 text-[11px] overflow-x-auto">{ejemplo_solicitud(@endpoint, @parametros_elegibles, @prefijo)}</pre>
            </div>
            <div>
              <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-1">Ejemplo de respuesta</div>
              <pre class="bg-gray-900 text-gray-100 rounded-lg px-3 py-2 text-[11px] overflow-x-auto">{documentacion_ejemplo()}</pre>
            </div>
          </div>
        </div>

        <!-- Modo alta (R54-R58) -- los campos que se documentan acá son
             los REALES del catálogo (@campos_reales_alta), no los
             parámetros de filtro -- son dos conceptos distintos en este
             modo. -->
        <div :if={@endpoint.permite_alta} class="grid grid-cols-1 lg:grid-cols-[1fr_340px] gap-6 items-start">
          <div>
            <div :if={@endpoint.campos_alta == []} class="text-xs text-gray-400">Todavía no habilitaste ningún campo en "Alta de registros", arriba.</div>
            <div :for={campo <- Enum.filter(@campos_reales_alta, &(&1.clave in @endpoint.campos_alta))} class="py-3 border-b border-gray-100 last:border-0">
              <div class="flex items-center gap-2 flex-wrap mb-1">
                <span class="font-mono text-sm font-semibold text-blue-600">{campo.clave}</span>
                <span class="text-[10px] font-semibold px-1.5 py-0.5 rounded bg-gray-100 text-gray-500">{campo.tipo}{tipo_hint(campo.tipo)}</span>
                <span class={[
                  "text-[10px] font-bold uppercase tracking-wide px-1.5 py-0.5 rounded",
                  campo.obligatorio && "bg-amber-100 text-amber-700",
                  !campo.obligatorio && "bg-gray-100 text-gray-400"
                ]}>
                  {if campo.obligatorio, do: "Obligatorio", else: "Opcional"}
                </span>
              </div>
              <p class="text-sm text-gray-700 font-medium">{campo.etiqueta}</p>
            </div>

            <div :for={detalle <- @catalogos_detalle_alta} :if={renglon_campos_actuales(@endpoint, detalle.nombre) != []} class="py-3 border-b border-gray-100 last:border-0">
              <p class="text-sm text-gray-700 font-medium mb-1">Renglones · {detalle.etiqueta} <span class="font-mono text-gray-400 text-xs">({detalle.nombre})</span></p>
              <div :for={campo <- Enum.filter(detalle.campos, &(&1.clave in renglon_campos_actuales(@endpoint, detalle.nombre)))} class="flex items-center gap-2 flex-wrap mb-1">
                <span class="font-mono text-sm font-semibold text-blue-600">{campo.clave}</span>
                <span class="text-[10px] font-semibold px-1.5 py-0.5 rounded bg-gray-100 text-gray-500">{campo.tipo}{tipo_hint(campo.tipo)}</span>
              </div>
            </div>
          </div>

          <div class="lg:sticky lg:top-4 flex flex-col gap-3">
            <div>
              <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-1">Ejemplo de solicitud</div>
              <pre class="bg-gray-900 text-gray-100 rounded-lg px-3 py-2 text-[11px] overflow-x-auto">{ejemplo_alta(@endpoint, @campos_reales_alta, @catalogos_detalle_alta, @prefijo)}</pre>
            </div>
            <div>
              <div class="text-[11px] font-bold uppercase tracking-wide text-gray-400 mb-1">Ejemplo de respuesta</div>
              <pre class="bg-gray-900 text-gray-100 rounded-lg px-3 py-2 text-[11px] overflow-x-auto">{documentacion_ejemplo_alta()}</pre>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :campos, :list, required: true
  attr :multi_tabla?, :boolean, required: true
  attr :detalles_por_catalogo, :map, required: true
  attr :modos_fecha_rango, :list, required: true
  attr :modos_fecha_simple, :list, required: true
  attr :catalogos_referenciables, :list, required: true

  # Equivalente reducido a la sección "Columnas del GET" de Get Config
  # (ConsultaEditorLive) -- Visible/Parámetro y su configuración, SIN
  # reordenamiento por drag-and-drop ni Campos de control/Orden de
  # resultados (siguen siendo exclusivos de esa pantalla, un endpoint no
  # los necesita para funcionar).
  defp panel_campos(assigns) do
    ~H"""
    <div class="bg-white border border-gray-200 rounded-2xl shadow-sm">
      <div class="px-4 pt-4 text-[11px] font-bold uppercase tracking-wide text-gray-400">
        Campos -- qué se ve en la respuesta ("Visible") y qué se puede filtrar ("Parámetro")
      </div>
      <form id="form-guardar-columnas" phx-submit="guardar_columnas" class="hidden" aria-hidden="true"></form>

      <div class="overflow-x-auto rounded-t-2xl mt-2">
        <table class="min-w-full divide-y divide-gray-200 text-xs">
          <thead class="bg-gray-50">
            <tr>
              <th :if={@multi_tabla?} class="px-1.5 py-1.5 text-left font-semibold text-gray-500 uppercase tracking-wide">Tabla</th>
              <th class="px-1.5 py-1.5 text-left font-semibold text-gray-500 uppercase tracking-wide">Campo</th>
              <th class="px-1.5 py-1.5 text-left font-semibold text-gray-500 uppercase tracking-wide">Etq</th>
              <th class="px-1.5 py-1.5 text-center font-semibold text-gray-500 uppercase tracking-wide">Vis.</th>
              <th class="px-1.5 py-1.5 text-center font-semibold text-gray-500 uppercase tracking-wide">Param</th>
              <th class="px-1.5 py-1.5 text-left font-semibold text-gray-500 uppercase tracking-wide">Tipo</th>
              <th class="px-1.5 py-1.5 text-center font-semibold text-gray-500 uppercase tracking-wide">Acot.</th>
              <th class="px-1.5 py-1.5 text-left font-semibold text-gray-500 uppercase tracking-wide">Default</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <tr :for={campo <- @campos} id={"columna-endpoint-row-#{identificador(campo)}"}>
              <td :if={@multi_tabla?} class="px-1.5 py-1.5 text-gray-500 font-mono max-w-[7rem] truncate" title={campo["catalogo"]}>{campo["catalogo"]}</td>
              <td class="px-1.5 py-1.5 text-gray-500 font-mono max-w-[9rem] truncate" title={campo["campo"]}>{campo["campo"]}</td>
              <td class="px-1.5 py-1.5 text-gray-700 max-w-[6rem] truncate" title={campo["etiqueta"]}>{campo["etiqueta"]}</td>
              <td class="px-1.5 py-1.5 text-center">
                <input type="checkbox" form="form-guardar-columnas" name="visibles[]" value={identificador(campo)} checked={campo["visible"]} class="accent-purple-600" />
              </td>
              <td class="px-1.5 py-1.5 text-center">
                <.toggle_es_parametro :if={MetaConsultas.tipo_elegible?(MetaConsultas.tipo_efectivo(campo))} campo={campo} id={identificador(campo)} />
                <span :if={!MetaConsultas.tipo_elegible?(MetaConsultas.tipo_efectivo(campo))} class="text-[10px] text-gray-300" title="Tipo sin parámetro estándar">—</span>
              </td>
              <.celdas_parametro campo={campo} tipo_efectivo={MetaConsultas.tipo_efectivo(campo)} form_id="form-guardar-columnas" modos_fecha_rango={@modos_fecha_rango} modos_fecha_simple={@modos_fecha_simple}
                catalogos_referenciables={@catalogos_referenciables} detalles_por_catalogo={@detalles_por_catalogo} />
            </tr>
            <tr :if={@campos == []}>
              <td colspan={if @multi_tabla?, do: 8, else: 7} class="px-1.5 py-6 text-center text-gray-400">Esta consulta no tiene campos.</td>
            </tr>
          </tbody>
        </table>
      </div>
      <div class="px-4 py-3 border-t border-gray-200">
        <button type="submit" form="form-guardar-columnas" class="px-4 py-2 rounded-lg bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700">
          Guardar columnas
        </button>
      </div>
    </div>
    """
  end

  # R62-R64 -- aviso inline para que quede claro, en la propia UI, que
  # un campo "referencia" espera la descripción del registro
  # referenciado, no su id interno -- y que una descripción repetida
  # rechaza el alta en vez de adivinar cuál usar (ver
  # ConsultaEndpoints.resolver_referencias_por_descripcion/2).
  defp tipo_hint("referencia"), do: " (por descripción, debe ser única)"
  defp tipo_hint(_otro), do: ""

  defp campo_tipo(parametros_elegibles, clave) do
    case Enum.find(parametros_elegibles, &(&1["clave"] == clave)) do
      nil -> "?"
      campo -> campo["tipo"]
    end
  end

  defp etiqueta_parametro(parametros_elegibles, clave) do
    case Enum.find(parametros_elegibles, &(&1["clave"] == clave)) do
      nil -> clave
      campo -> campo["etiqueta"] || clave
    end
  end

  defp renglon_campos_actuales(nil, _catalogo), do: []

  defp renglon_campos_actuales(endpoint, catalogo) do
    case Enum.find(endpoint.renglones_alta, &(&1["catalogo"] == catalogo)) do
      nil -> []
      entrada -> entrada["campos"] || []
    end
  end

  defp descripcion_actual(nil, _clave), do: ""

  defp descripcion_actual(endpoint, clave) do
    case Enum.find(endpoint.parametros, &(&1["campo"] == clave)) do
      nil -> ""
      p -> p["descripcion"] || ""
    end
  end

  defp ejemplo_solicitud(endpoint, parametros_elegibles, prefijo) do
    ruta_completa = "#{prefijo}#{endpoint.ruta}"

    pares =
      Enum.flat_map(endpoint.parametros, fn %{"campo" => clave} ->
        parametros_elegibles
        |> Enum.find(&(&1["clave"] == clave))
        |> valores_ejemplo(clave)
      end)

    case endpoint.metodo do
      "get" ->
        query =
          (pares ++ [{"pagina", "1"}, {"por_pagina", "50"}])
          |> Enum.map(fn {k, v} -> "#{k}=#{valor_a_texto(v)}" end)
          |> Enum.join("&")

        "GET #{ruta_completa}?#{query}\nAuthorization: Bearer <api_key>"

      "post" ->
        json = pares |> Map.new() |> Jason.encode!(pretty: true)
        "POST #{ruta_completa}\nAuthorization: Bearer <api_key>\nContent-Type: application/json\n\n#{json}"
    end
  end

  defp valor_a_texto(lista) when is_list(lista), do: Enum.join(lista, ",")
  defp valor_a_texto(valor), do: valor

  defp valores_ejemplo(%{"tipo" => "date", "acotado" => true}, clave),
    do: [{"#{clave}_desde", "2026-01-01"}, {"#{clave}_hasta", "2026-01-31"}]

  defp valores_ejemplo(%{"tipo" => "date"}, clave), do: [{clave, "2026-01-01"}]

  defp valores_ejemplo(%{"tipo" => tipo, "acotado" => true}, clave) when tipo in ["integer", "decimal"],
    do: [{"#{clave}_desde", "1"}, {"#{clave}_hasta", "100"}]

  defp valores_ejemplo(%{"tipo" => "integer"}, clave), do: [{clave, "1"}]
  defp valores_ejemplo(%{"tipo" => "decimal"}, clave), do: [{clave, "10.50"}]
  defp valores_ejemplo(%{"tipo_filtro" => "multi"}, clave), do: [{clave, ["valor1", "valor2"]}]
  defp valores_ejemplo(nil, clave), do: [{clave, "valor"}]
  defp valores_ejemplo(_campo, clave), do: [{clave, "texto"}]

  defp documentacion_ejemplo do
    """
    {
      "data": [ { "<catalogo>__<campo>": <valor>, ... }, ... ],
      "meta": { "pagina": 1, "por_pagina": 50, "total": 0, "total_paginas": 1 }
    }
    """
  end

  # R54-R58 -- ejemplo del body de alta: campos REALES (nombre crudo,
  # sin namespace de catálogo -- a diferencia de un filtro, acá se
  # inserta directo en la tabla) con un valor de ejemplo por tipo.
  # R59-R61 -- si hay renglones habilitados, se agregan bajo la clave
  # del catálogo detalle real (mismo shape que espera el body real,
  # ver ConsultaEndpoints.renglones_spec_desde_externos/2).
  defp ejemplo_alta(endpoint, campos_reales_alta, catalogos_detalle_alta, prefijo) do
    ruta_completa = "#{prefijo}#{endpoint.ruta}"

    encabezado =
      campos_reales_alta
      |> Enum.filter(&(&1.clave in endpoint.campos_alta))
      |> Map.new(&{&1.clave, valor_ejemplo_tipo(&1.tipo)})

    renglones =
      Enum.reduce(catalogos_detalle_alta, %{}, fn detalle, acc ->
        campos = renglon_campos_actuales(endpoint, detalle.nombre)

        if campos == [] do
          acc
        else
          item =
            detalle.campos
            |> Enum.filter(&(&1.clave in campos))
            |> Map.new(&{&1.clave, valor_ejemplo_tipo(&1.tipo)})

          Map.put(acc, detalle.nombre, [item])
        end
      end)

    json = encabezado |> Map.merge(renglones) |> Jason.encode!(pretty: true)

    "POST #{ruta_completa}\nAuthorization: Bearer <api_key>\nContent-Type: application/json\n\n#{json}"
  end

  defp valor_ejemplo_tipo("date"), do: "2026-01-01"
  defp valor_ejemplo_tipo("integer"), do: 1
  defp valor_ejemplo_tipo("decimal"), do: 10.50
  defp valor_ejemplo_tipo("boolean"), do: true
  # R62-R64 -- un campo "referencia" se identifica por su campo de
  # descripción (acompañamiento), nunca por el id interno -- ver
  # ConsultaEndpoints.resolver_referencias_por_descripcion/2.
  defp valor_ejemplo_tipo("referencia"), do: "<descripción exacta del registro referenciado>"
  defp valor_ejemplo_tipo(_otro), do: "texto"

  defp documentacion_ejemplo_alta do
    """
    HTTP 201 Created
    { "data": { "id": <id_del_registro_nuevo> } }
    """
  end
end
