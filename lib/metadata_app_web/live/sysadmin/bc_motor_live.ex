defmodule MetadataAppWeb.Sysadmin.BcMotorLive do
  # Plan de UI del Motor de Estados, construido por fases (ver memoria del
  # proyecto): Fase 2 (Estados + panel de salud), Fase 3 (Transiciones),
  # Fase 4 (diagrama Mermaid) — las tres de solo lectura. Fase 5 (acá) suma
  # la primera escritura real: agregar/quitar Reglas sobre transiciones que
  # YA existen. Sigue sin haber wizard de creación completa (eso usa
  # MetaEstadosAdmin.crear_proceso_completo/1, Fase 1, atómico) ni edición
  # de Estados/Transiciones en sí — eso queda para después.
  use MetadataAppWeb, :live_view_admin

  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerador}
  alias MetadataApp.MetaEstadosAdmin
  alias MetadataApp.MetaReglasCodigo
  alias MetadataAppWeb.AdminNav
  alias Phoenix.LiveView.JS

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"}
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
        %{nombre: h.schema_context_name, etiqueta: h.schema_context_label, campos: MetaSchemaContext.listar_detalles(h.schema_context_name)}
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
          "schema_context_icono" => nil_si_vacio(normalizar_icono(params["icono"]))
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
    {:noreply,
     assign(socket, :campo_form, %{
       "nombre" => "",
       "etiqueta" => "",
       "tipo" => "string",
       "longitud" => "",
       "precision" => "",
       "escala" => "",
       "catalogo" => "",
       "opcional" => true,
       "valor_default" => "",
       "error" => nil
     })}
  end

  def handle_event("cerrar_form_campo", _params, socket) do
    {:noreply, assign(socket, :campo_form, nil)}
  end

  # Solo existe para que el modal reaccione en vivo al elegir "referencia"
  # en Tipo (mostrar/ocultar el selector de Catálogo destino).
  def handle_event("validar_campo", params, socket) do
    campo_form = %{
      "nombre" => params["nombre"] || "",
      "etiqueta" => params["etiqueta"] || "",
      "tipo" => params["tipo"] || "string",
      "longitud" => params["longitud"] || "",
      "precision" => params["precision"] || "",
      "escala" => params["escala"] || "",
      "catalogo" => params["catalogo"] || "",
      "opcional" => params["opcional"] == "true",
      "valor_default" => params["valor_default"] || "",
      "error" => nil
    }

    {:noreply, assign(socket, :campo_form, campo_form)}
  end

  # Referencia (correcciones de compliance): nombre/etiqueta/opcional NUNCA
  # vienen del form — se derivan del catálogo destino, siempre obligatoria.
  # Cualquier otro tipo sigue el camino de siempre (nombre/etiqueta a mano).
  def handle_event("guardar_campo", %{"tipo" => "referencia"} = params, socket) do
    header = socket.assigns.header
    catalogo = params["catalogo"] || ""

    case catalogo do
      "" ->
        {:noreply, update(socket, :campo_form, &Map.put(&1, "error", "Elegí a qué catálogo apunta la referencia."))}

      _catalogo ->
        case MetaSchemaContext.obtener_header_por_nombre(catalogo) do
          nil ->
            {:noreply, update(socket, :campo_form, &Map.put(&1, "error", "Ese catálogo destino ya no existe."))}

          destino ->
            nombre = "#{header.schema_context_name}_#{String.replace_prefix(catalogo, "pty_", "")}"

            # El nombre se auto-deriva del catálogo destino — dos referencias
            # al MISMO catálogo producen el mismo nombre. El índice único de
            # meta_schema_detail ya lo bloquea de fondo, pero acá se corta
            # antes, con un mensaje específico (evita el genérico "has
            # already been taken" del constraint).
            if Enum.any?(socket.assigns.campos, &(&1.schema_context_field == nombre)) do
              {:noreply,
               update(
                 socket,
                 :campo_form,
                 &Map.put(&1, "error", "Ya existe un campo que referencia a #{destino.schema_context_label} en este catálogo.")
               )}
            else
              propiedades = %{
                "etiqueta" => destino.schema_context_label,
                "tipo" => "referencia",
                "orden" => length(socket.assigns.campos) + 1,
                "visible" => true,
                "editable" => true,
                "opcional" => false,
                "catalogo" => catalogo
              }

              guardar_campo_y_generar(socket, header, nombre, propiedades)
            end
        end
    end
  end

  def handle_event("guardar_campo", params, socket) do
    header = socket.assigns.header
    sufijo = String.trim(params["nombre"] || "")
    etiqueta = String.trim(params["etiqueta"] || "")
    tipo = params["tipo"] || "string"
    opcional = params["opcional"] == "true"
    valor_default = String.trim(params["valor_default"] || "")
    nombre = "#{header.schema_context_name}_#{sufijo}"

    cond do
      not Regex.match?(~r/^[a-z][a-z0-9_]{0,49}$/, sufijo) ->
        {:noreply,
         update(
           socket,
           :campo_form,
           &Map.put(&1, "error", "Nombre inválido — minúsculas, sin acentos ni espacios, debe empezar con una letra.")
         )}

      etiqueta == "" ->
        {:noreply, update(socket, :campo_form, &Map.put(&1, "error", "La etiqueta no puede quedar vacía."))}

      not opcional and valor_default != "" and not valor_default_valido?(tipo, valor_default) ->
        {:noreply, update(socket, :campo_form, &Map.put(&1, "error", mensaje_valor_default_invalido(tipo)))}

      true ->
        propiedades =
          %{
            "etiqueta" => etiqueta,
            "tipo" => tipo,
            "orden" => length(socket.assigns.campos) + 1,
            "visible" => true,
            "editable" => true,
            "opcional" => opcional
          }
          |> agregar_opciones_tipo_campo(tipo, params)
          |> agregar_valor_default(opcional, valor_default)

        guardar_campo_y_generar(socket, header, nombre, propiedades)
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
       "error" => nil
     })}
  end

  def handle_event("cerrar_form_transicion", _params, socket) do
    {:noreply, assign(socket, :transicion_form, nil)}
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

  defp agregar_opciones_tipo_campo(propiedades, "string", params), do: maybe_put_int(propiedades, "longitud", params["longitud"])

  defp agregar_opciones_tipo_campo(propiedades, "decimal", params),
    do: propiedades |> maybe_put_int("precision", params["precision"]) |> maybe_put_int("escala", params["escala"])

  defp agregar_opciones_tipo_campo(propiedades, "referencia", params), do: Map.put(propiedades, "catalogo", params["catalogo"])

  defp agregar_opciones_tipo_campo(propiedades, _tipo, _params), do: propiedades

  # El campo "Valor por default" solo tiene sentido para un campo
  # OBLIGATORIO agregado a un catálogo que ya existe (ver
  # CatalogoGenerador.columna_migracion_agregar/3 y
  # docs/catalogo-maestro-detalle-requerimientos.md §R13) — si es
  # opcional o no se completó, no se manda la propiedad.
  defp agregar_valor_default(propiedades, true, _valor), do: propiedades
  defp agregar_valor_default(propiedades, false, ""), do: propiedades
  defp agregar_valor_default(propiedades, false, valor), do: Map.put(propiedades, "valor_default", valor)

  defp valor_default_valido?("integer", valor), do: Regex.match?(~r/^-?\d+$/, valor)
  defp valor_default_valido?("decimal", valor), do: Regex.match?(~r/^-?\d+(\.\d+)?$/, valor)
  defp valor_default_valido?("boolean", valor), do: valor in ["true", "false"]
  defp valor_default_valido?("date", valor), do: match?({:ok, _}, Date.from_iso8601(valor))
  defp valor_default_valido?(_tipo, _valor), do: true

  defp mensaje_valor_default_invalido("integer"), do: "El valor por default tiene que ser un número entero."
  defp mensaje_valor_default_invalido("decimal"), do: "El valor por default tiene que ser un número (con decimales si hace falta)."
  defp mensaje_valor_default_invalido("boolean"), do: "El valor por default tiene que ser Verdadero o Falso."
  defp mensaje_valor_default_invalido("date"), do: "El valor por default tiene que ser una fecha válida."
  defp mensaje_valor_default_invalido(_tipo), do: "Valor por default inválido."

  defp placeholder_valor_default("integer"), do: "0"
  defp placeholder_valor_default("decimal"), do: "0.00"
  defp placeholder_valor_default(_tipo), do: "texto"

  defp maybe_put_int(map, _key, val) when val in ["", nil], do: map

  defp maybe_put_int(map, key, val) do
    case Integer.parse(val) do
      {n, _} -> Map.put(map, key, n)
      :error -> map
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

      <.motor_stepper pasos={pasos_motor(@completitud, @transiciones, @es_detalle?)} />
      <.panel_problemas :if={@validacion.problemas != []} problemas={@validacion.problemas} />

      <.tabs_motor id="motor" tabs={
        [%{key: "config", label: "Configuración"}, %{key: "reglas", label: "Reglas"}] ++
          if(@es_detalle?, do: [], else: [%{key: "diagrama", label: "Diagrama"}, %{key: "api", label: "Contrato"}])
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

      <%= unless @es_detalle? do %>
        <div id="motor-panel-diagrama" class="hidden">
          <.diagrama_transiciones diagrama={@diagrama} />
        </div>

        <div id="motor-panel-api" class="hidden">
          <.panel_api header={@header} campos={@campos} estados={@estados} transiciones={@transiciones} />
        </div>
      <% end %>
    </div>

    <.modal_campo :if={@campo_form} form={@campo_form} catalogos={@catalogos_referenciables} nombre_base={@header.schema_context_name} />
    <.modal_eliminar_campo :if={@eliminar_campo_form} form={@eliminar_campo_form} />
    <.modal_estado :if={@estado_form} form={@estado_form} />
    <.modal_transicion :if={@transicion_form} form={@transicion_form} estados={@estados} campos={@campos} catalogos_detalle={@catalogos_detalle} />
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
  # ni hace falta que lo hagan).
  defp pasos_motor(completitud, _transiciones, true) do
    [
      {"Campos", completitud.tiene_campos},
      {"Reglas", not completitud.reglas.pre_pendiente and not completitud.reglas.post_pendiente}
    ]
    |> marcar_estado_pasos()
  end

  defp pasos_motor(completitud, transiciones, false) do
    tiene_transiciones? = transiciones != [] and completitud.transiciones_self_loop_sin_campos_editables == 0

    # "Estado inicial" antes que "Estados" (invertido 2026-07-21, a pedido
    # explícito): ahora coinciden siempre en el mismo momento — el primer
    # Estado que se crea ya nace forzado como inicial (ver
    # MetaEstadosAdmin.crear_estado/1) — el orden nuevo refleja que
    # establecer el inicial es lo que de verdad importa primero, no una
    # etapa separada que viene después de tener "estados" en plural.
    [
      {"Campos", completitud.tiene_campos},
      {"Estado inicial", completitud.tiene_alta_o_inicial},
      {"Estados", completitud.tiene_estados},
      {"Transiciones", tiene_transiciones?},
      {"Reglas", not completitud.reglas.pre_pendiente and not completitud.reglas.post_pendiente}
    ]
    |> marcar_estado_pasos()
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
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Nombre</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Etiqueta</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Tipo</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Opcional</th>
                <th class="px-1.5 py-1 border-b border-gray-200"></th>
              </tr>
            </thead>
            <tbody>
              <%= for c <- @campos do %>
                <% props = c.schema_context_properties || %{} %>
                <tr class="border-b border-gray-100 hover:bg-gray-50">
                  <td class="px-1.5 py-1 text-gray-900 font-mono">{c.schema_context_field}</td>
                  <td class="px-1.5 py-1 text-gray-700">{Map.get(props, "etiqueta")}</td>
                  <td class="px-1.5 py-1 text-gray-600">{Map.get(props, "tipo")}</td>
                  <td class="px-1.5 py-1 text-gray-600">{if Map.get(props, "opcional"), do: "Sí", else: "—"}</td>
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
      <div class="bg-blue-50 border border-blue-200 text-blue-800 rounded-lg px-3 py-2">
        <p>
          Mismo endpoint genérico para cualquier catálogo — lo único que cambia entre uno y otro es la tabla y sus
          campos. El body de POST acepta los campos sueltos (como abajo) o envueltos bajo la clave del catálogo,
          <span class="font-mono">{@ejemplo_wrap}</span> — las dos formas funcionan.
        </p>
        <p class="mt-1">
          <span class="font-mono">POST /api/{@tabla}</span> también acepta un <strong>lote</strong>: si el body es
          una lista en vez de un objeto (envuelta bajo la clave del catálogo, como en el ejemplo de abajo), crea
          todos los registros en un solo request — pensado para cargas de más de un registro, el caso más común en
          la práctica.
        </p>
        <p :if={@tiene_estados} class="mt-1">
          <span class="font-mono">estado_id</span> nunca se manda en el body de POST — el estado solo cambia con
          <span class="font-mono">POST /api/{@tabla}/:id/transiciones/:accion</span>. Si esa transición tiene campos
          editables configurados, van en el mismo body y se aplican junto con el cambio de estado.
        </p>
        <p :if={@tiene_detalles} class="mt-1">
          Este catálogo es maestro de {length(@catalogos_detalle)}
          {if length(@catalogos_detalle) == 1, do: "catálogo detalle", else: "catálogos detalle"}
          (<span :for={{c, i} <- Enum.with_index(@catalogos_detalle)} class="font-mono">{if i > 0, do: ", "}{c.schema_context_name}</span>).
          Sus renglones viajan bajo la clave <span class="font-mono">"renglones"</span>, tanto al <strong>crear</strong>
          (<span class="font-mono">POST /api/{@tabla}</span>, alta atómica — encabezado + renglones iniciales en un
          solo request, sin `renglon_id` porque son altas nuevas) como al <strong>transicionar</strong>
          (<span class="font-mono">POST .../transiciones/:accion</span>, con <span class="font-mono">renglon_id</span>
          porque ahí seleccionás renglones que ya existen — pelado para solo mover estado, o con más campos si esa
          transición los permite editar).
        </p>
      </div>

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

  @tipos_campo ~w(string integer decimal boolean date enum referencia)

  attr :form, :map, required: true
  attr :catalogos, :list, required: true
  attr :nombre_base, :string, required: true

  defp modal_campo(assigns) do
    assigns = assign(assigns, :tipos, @tipos_campo)

    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div class="bg-white rounded-xl shadow-lg max-w-sm w-full p-4 text-xs">
        <h2 class="text-sm font-bold text-gray-900 mb-3">Agregar campo</h2>

        <%= if @form["error"] do %>
          <div class="bg-red-50 text-red-700 rounded-lg px-2 py-1.5 mb-2">{@form["error"]}</div>
        <% end %>

        <form phx-submit="guardar_campo" phx-change="validar_campo" class="space-y-2">
          <div>
            <label class="block text-gray-700 mb-0.5">Tipo</label>
            <select name="tipo" class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
              <%= for tipo <- @tipos do %>
                <option value={tipo} selected={@form["tipo"] == tipo}>{tipo}</option>
              <% end %>
            </select>
          </div>

          <%!-- Referencia: nombre/etiqueta/longitud/precisión/escala/opcional
               NO se capturan — se derivan del catálogo destino (nombre y
               etiqueta) o no aplican (una referencia es un entero, no tiene
               longitud). Siempre obligatoria, sin excepción — nunca se
               ofrece "Opcional" para este tipo. --%>
          <%= if @form["tipo"] == "referencia" do %>
            <div>
              <label class="block text-gray-700 mb-0.5">Catálogo destino</label>
              <select name="catalogo" class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
                <option value="">— Elegir —</option>
                <%= for c <- @catalogos do %>
                  <option value={c.nombre} selected={@form["catalogo"] == c.nombre}>{c.etiqueta}</option>
                <% end %>
              </select>
              <p class="mt-0.5 text-gray-500">
                El nombre, la etiqueta y el resto de las propiedades del campo se toman del catálogo elegido — siempre obligatorio.
              </p>
            </div>
          <% else %>
            <div>
              <label class="block text-gray-700 mb-0.5">Nombre</label>
              <input type="text" name="nombre" value={@form["nombre"]} placeholder="color" required
                pattern="[a-z][a-z0-9_]*" maxlength="50"
                class="w-full border border-gray-300 rounded-lg px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />
              <p class="mt-0.5 text-gray-500">
                Se va a crear como <strong class="font-mono">{@nombre_base}_{if @form["nombre"] in [nil, ""], do: "…", else: @form["nombre"]}</strong>
              </p>
            </div>
            <div>
              <label class="block text-gray-700 mb-0.5">Etiqueta</label>
              <input type="text" name="etiqueta" value={@form["etiqueta"]} required maxlength="100"
                class="w-full border border-gray-300 rounded-lg px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />
            </div>
            <div class="grid grid-cols-3 gap-2">
              <div>
                <label class="block text-gray-700 mb-0.5">longitud</label>
                <input type="number" name="longitud" value={@form["longitud"]} class="w-full border border-gray-300 rounded-lg px-2 py-1" />
              </div>
              <div>
                <label class="block text-gray-700 mb-0.5">precisión</label>
                <input type="number" name="precision" value={@form["precision"]} class="w-full border border-gray-300 rounded-lg px-2 py-1" />
              </div>
              <div>
                <label class="block text-gray-700 mb-0.5">escala</label>
                <input type="number" name="escala" value={@form["escala"]} class="w-full border border-gray-300 rounded-lg px-2 py-1" />
              </div>
            </div>
            <label class="flex items-center gap-1.5">
              <input type="hidden" name="opcional" value="false" />
              <input type="checkbox" name="opcional" value="true" checked={@form["opcional"] == true} class="accent-purple-600" />
              Opcional (recomendado — el catálogo ya puede tener filas sin este campo)
            </label>

            <%!-- Solo tiene sentido para un campo OBLIGATORIO en un catálogo que
                 YA existe (BcMotorLive siempre opera sobre uno ya generado —
                 ver CatalogoGenerador.columna_migracion_agregar/3): sin esto,
                 agregar un campo obligatorio a una tabla con millones de filas
                 queda "obligatorio de palabra" (nullable en Postgres, exigido
                 solo desde la app en adelante). Con un valor acá, Postgres 11+
                 lo aplica de una como NOT NULL real, sin reescribir la tabla. --%>
            <div :if={@form["opcional"] != true}>
              <label class="block text-gray-700 mb-0.5">Valor por default (opcional)</label>
              <%= if @form["tipo"] == "boolean" do %>
                <select name="valor_default" class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
                  <option value="" selected={@form["valor_default"] in [nil, ""]}>— Sin default (nullable en filas viejas) —</option>
                  <option value="true" selected={@form["valor_default"] == "true"}>Verdadero</option>
                  <option value="false" selected={@form["valor_default"] == "false"}>Falso</option>
                </select>
              <% else %>
                <input
                  type={if @form["tipo"] == "date", do: "date", else: "text"}
                  name="valor_default"
                  value={@form["valor_default"]}
                  placeholder={placeholder_valor_default(@form["tipo"])}
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500"
                />
              <% end %>
              <p class="mt-0.5 text-gray-500">
                Sin default, el campo queda obligatorio solo desde ahora (filas viejas se quedan sin valor). Con un
                default, las filas viejas también lo reciben y el campo queda realmente NOT NULL — instantáneo aunque
                el catálogo tenga millones de filas.
              </p>
            </div>
          <% end %>

          <div class="flex justify-end gap-2 pt-2">
            <button type="button" phx-click="cerrar_form_campo" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
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

        <form phx-submit="guardar_transicion" class="space-y-2">
          <input type="hidden" name="registro_id" value={@form["id"]} />
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

          <%!-- Catálogo Maestro-Detalle (R4): un campo de un catálogo detalle
               es tan "editable en esta transición" como uno del propio
               maestro (el motor ya lo acepta desde Fase 3). Con 1 maestro +
               N detalles de hasta 20-30 campos, listar todo suelto es
               inmanejable — se organiza en tabs (una por catálogo,
               tabs_motor ya es 100% cliente/JS, no pierde selección de
               otros tabs al cambiar) + buscador por tab + "Todos/Ninguno".
               Un solo <input name="campos_editables[]"> compartido entre
               TODOS los tabs (siguen en el DOM aunque el tab esté oculto,
               solo con display:none) — el submit junta la selección real
               sin importar en qué tab haya quedado parado el usuario. --%>
          <%= if @campos != [] or @catalogos_detalle != [] do %>
            <div>
              <label class="block text-gray-700 mb-1">Campos editables en esta transición</label>

              <.tabs_motor id="campos-editables" tabs={
                [%{key: "header", label: "Encabezado"}] ++ Enum.map(@catalogos_detalle, &%{key: &1.nombre, label: &1.etiqueta})
              } />

              <div id="campos-editables-panel-header">
                <.grupo_campos_editables grupo="header" campos={@campos} form={@form} />
              </div>
              <%= for cat <- @catalogos_detalle do %>
                <div id={"campos-editables-panel-#{cat.nombre}"} class="hidden">
                  <.grupo_campos_editables grupo={cat.nombre} campos={cat.campos} form={@form} />
                </div>
              <% end %>
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
      <div class="grid grid-cols-2 gap-x-2 gap-y-1 max-h-48 overflow-y-auto border border-gray-200 rounded-lg p-1.5">
        <%= for c <- @visibles do %>
          <label class="flex items-center gap-1 min-w-0">
            <input type="checkbox" name="campos_editables[]" value={c.schema_context_field}
              checked={c.schema_context_field in @seleccionados} class="accent-purple-600 shrink-0" />
            <span class="font-mono truncate" title={c.schema_context_field}>{c.schema_context_field}</span>
          </label>
        <% end %>
        <%= if @visibles == [] do %>
          <p class="col-span-2 text-gray-400 text-center py-2">Sin resultados.</p>
        <% end %>
      </div>
    </div>
    """
  end
end
