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
  alias Phoenix.LiveView.JS

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"}
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
      |> assign(:regla_form, nil)
      |> assign(:campo_form, nil)
      |> assign(:eliminar_campo_form, nil)
      |> assign(:estado_form, nil)
      |> assign(:transicion_form, nil)
      |> assign(:header, header)
      |> assign(:header_form, header_form_desde(header))
      |> assign(:iconos_sugeridos, @iconos_sugeridos)
      |> assign(:carpetas, MetaSchemaContext.listar_carpetas_existentes())
      |> assign(:catalogos_referenciables, MetaSchemaContext.listar_catalogos_referenciables())

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

    socket
    |> assign(:campos, MetaSchemaContext.listar_detalles(header.schema_context_name))
    |> assign(:estados, estados)
    |> assign(:estados_por_id, Map.new(estados, &{&1.id, &1}))
    |> assign(:transiciones, transiciones)
    |> assign(:diagrama, diagrama_mermaid(estados, transiciones))
    |> assign(:completitud, completitud)
    |> assign(:validacion, validacion)
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
      "error" => nil
    }

    {:noreply, assign(socket, :campo_form, campo_form)}
  end

  def handle_event("guardar_campo", params, socket) do
    header = socket.assigns.header
    nombre = String.trim(params["nombre"] || "")
    etiqueta = String.trim(params["etiqueta"] || "")
    tipo = params["tipo"] || "string"
    catalogo = params["catalogo"] || ""

    cond do
      not Regex.match?(~r/^[a-z][a-z0-9_]{0,49}$/, nombre) ->
        {:noreply,
         update(
           socket,
           :campo_form,
           &Map.put(&1, "error", "Nombre inválido — minúsculas, sin acentos ni espacios, debe empezar con una letra.")
         )}

      etiqueta == "" ->
        {:noreply, update(socket, :campo_form, &Map.put(&1, "error", "La etiqueta no puede quedar vacía."))}

      tipo == "referencia" and catalogo == "" ->
        {:noreply, update(socket, :campo_form, &Map.put(&1, "error", "Elegí a qué catálogo apunta la referencia."))}

      true ->
        propiedades =
          %{
            "etiqueta" => etiqueta,
            "tipo" => tipo,
            "orden" => length(socket.assigns.campos) + 1,
            "visible" => true,
            "editable" => true,
            "opcional" => params["opcional"] == "true"
          }
          |> agregar_opciones_tipo_campo(tipo, params)

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
      {:noreply,
       assign(socket, :estado_form, %{
         "id" => nil,
         "nombre" => "",
         "orden" => to_string(length(socket.assigns.estados) + 1),
         "es_inicial" => false,
         "color" => "#7c3aed",
         "icono" => "",
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
       "color" => estado.color || "#7c3aed",
       "icono" => estado.icono || "",
       "error" => nil
     })}
  end

  def handle_event("cerrar_form_estado", _params, socket) do
    {:noreply, assign(socket, :estado_form, nil)}
  end

  def handle_event("elegir_icono_estado", %{"icono" => icono}, socket) do
    {:noreply, update(socket, :estado_form, &Map.put(&1, "icono", icono))}
  end

  def handle_event("guardar_estado", params, socket) do
    nombre = String.trim(params["nombre"] || "")

    attrs = %{
      "meta_schema_header_id" => socket.assigns.header.id,
      "nombre" => nombre,
      "orden" => params["orden"],
      "es_inicial" => params["es_inicial"] == "true",
      "color" => nil_si_vacio(params["color"]),
      "icono" => nil_si_vacio(normalizar_icono(params["icono"]))
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
       "error" => nil
     })}
  end

  def handle_event("cerrar_form_transicion", _params, socket) do
    {:noreply, assign(socket, :transicion_form, nil)}
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

  # --- Reglas: vocabulario cerrado --------------------------------------------

  def handle_event("abrir_form_regla", %{"transicion_id" => id, "accion" => accion}, socket) do
    {:noreply,
     assign(socket, :regla_form, %{
       transicion_id: String.to_integer(id),
       accion: accion,
       regla: nil,
       error: nil
     })}
  end

  def handle_event("cerrar_form_regla", _params, socket) do
    {:noreply, assign(socket, :regla_form, nil)}
  end

  def handle_event("elegir_regla", %{"regla" => nombre}, socket) do
    nombre = if nombre == "", do: nil, else: nombre
    {:noreply, update(socket, :regla_form, &Map.put(&1, :regla, nombre))}
  end

  def handle_event("guardar_regla", %{"regla" => nombre} = params, socket) do
    case Map.fetch(MetaEstadosAdmin.vocabulario(), nombre) do
      {:ok, {tipo, _requeridos}} ->
        attrs = %{
          "transicion_id" => socket.assigns.regla_form.transicion_id,
          "tipo" => tipo,
          "regla" => nombre,
          "params" => normalizar_params_regla(nombre, Map.get(params, "params", %{})),
          "orden" => 0
        }

        case MetaEstadosAdmin.crear_regla(attrs) do
          {:ok, _regla} ->
            {:noreply,
             socket
             |> assign(:regla_form, nil)
             |> put_flash(:info, "Regla \"#{nombre}\" agregada.")
             |> cargar_motor()}

          {:error, changeset} ->
            {:noreply, update(socket, :regla_form, &Map.put(&1, :error, resumen_errores(changeset)))}
        end

      :error ->
        {:noreply, update(socket, :regla_form, &Map.put(&1, :error, "Elegí una regla de la lista."))}
    end
  end

  # --- Reglas: eliminar (vocabulario o de negocio) ----------------------------

  def handle_event("eliminar_regla", %{"id" => id}, socket) do
    id = String.to_integer(id)
    regla = socket.assigns.transiciones |> Enum.flat_map(& &1.reglas) |> Enum.find(&(&1.id == id))

    resultado = regla && MetaEstadosAdmin.eliminar_regla(regla)

    case resultado do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Regla eliminada.") |> cargar_motor()}

      _ ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar la regla.")}
    end
  end

  # --- Reglas: de negocio (andamiaje) -----------------------------------------

  def handle_event("andamiar_negocio", %{"transicion_id" => id, "tipo" => tipo}, socket) do
    id = String.to_integer(id)
    transicion = Enum.find(socket.assigns.transiciones, &(&1.id == id))
    catalogo = socket.assigns.header.schema_context_name

    case transicion && MetaEstadosAdmin.andamiar_regla_negocio(catalogo, transicion, tipo) do
      {:ok, %{creado?: true, ruta: ruta}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Stub creado y enganchado en #{ruta} — hay que completarlo en el editor de código.")
         |> cargar_motor()}

      {:ok, %{creado?: false, ruta: ruta}} ->
        {:noreply,
         socket
         |> put_flash(:info, "El archivo #{ruta} ya existía, solo se enganchó.")
         |> cargar_motor()}

      {:error, :ya_tiene_regla} ->
        {:noreply, put_flash(socket, :error, "Esa transición ya tiene una regla #{tipo}.")}

      _ ->
        {:noreply, put_flash(socket, :error, "No se pudo enganchar la regla de negocio.")}
    end
  end

  # --- Guardar BC: validar y exportar a JSON versionado -----------------------

  # Cada pieza (Estado/Transición/Regla/Campo) ya se persiste sola en la
  # base al crearla — "guardar" acá no significa insertar nada nuevo, sino
  # volcar la definición completa a priv/repo/catalogos/<catalogo>.meta.json
  # + .motor.json (lo que ya hacen mix meta.export/motor.export para TODOS
  # los catálogos, acá acotado a este solo). Sin esto, cualquier cosa
  # agregada por esta pantalla se pierde si alguien reproduce el entorno
  # desde cero sin acordarse de exportar a mano — el mismo gotcha que ya
  # documentamos más de una vez en este proyecto. No toca git — eso sigue
  # siendo `mix motor.publicar`, una acción aparte y más pesada.
  def handle_event("guardar_bc", _params, socket) do
    %{completitud: completitud, validacion: validacion, header: header} = socket.assigns

    if completitud.completo? and validacion.valido? do
      MetaSchemaContext.exportar_header(header)
      MetaEstadosAdmin.exportar_header(header)

      {:noreply,
       put_flash(
         socket,
         :info,
         "Guardado: priv/repo/catalogos/#{header.schema_context_name}.meta.json + .motor.json actualizados."
       )}
    else
      {:noreply,
       put_flash(socket, :error, "No se puede guardar todavía — hay problemas pendientes en el panel de validación.")}
    end
  end

  # campos_requeridos.campos: texto separado por coma -> lista, sin vacíos.
  defp normalizar_params_regla("campos_requeridos", %{"campos" => campos}) do
    lista = campos |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    %{"campos" => lista}
  end

  # mutar_relacionados.cambio es un mapa anidado {campo, valor} — el form
  # manda dos campos sueltos (cambio_campo/cambio_valor) que se combinan acá,
  # más simple que inventar una notación de objeto anidado en un <input>.
  defp normalizar_params_regla(
         "mutar_relacionados",
         %{"entidad" => entidad, "campo_relacion" => cr, "cambio_campo" => cc, "cambio_valor" => cv}
       ) do
    %{"entidad" => entidad, "campo_relacion" => cr, "cambio" => %{"campo" => cc, "valor" => cv}}
  end

  defp normalizar_params_regla(_regla, params), do: params

  defp agregar_opciones_tipo_campo(propiedades, "string", params), do: maybe_put_int(propiedades, "longitud", params["longitud"])

  defp agregar_opciones_tipo_campo(propiedades, "decimal", params),
    do: propiedades |> maybe_put_int("precision", params["precision"]) |> maybe_put_int("escala", params["escala"])

  defp agregar_opciones_tipo_campo(propiedades, "referencia", params), do: Map.put(propiedades, "catalogo", params["catalogo"])

  defp agregar_opciones_tipo_campo(propiedades, _tipo, _params), do: propiedades

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

  defp resumen_errores(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> inspect()
  end

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
        <div>
          <h1 class="text-lg font-bold text-gray-900">{@header.schema_context_label}</h1>
          <p class="mt-0.5 text-gray-500">
            <span class="font-mono">{@header.schema_context_name}</span>
            <span class="mx-1.5 text-gray-300">·</span>
            <span class="font-mono">{@header.schema_context_nav}</span>
          </p>
        </div>
        <button type="button" phx-click="guardar_bc"
          class="shrink-0 px-4 py-2 rounded-lg bg-purple-600 text-white font-bold hover:bg-purple-700 transition-colors">
          Guardar BC
        </button>
      </div>

      <.motor_stepper pasos={pasos_motor(@completitud, @transiciones)} />
      <.panel_problemas :if={@validacion.problemas != []} problemas={@validacion.problemas} />

      <div class="bg-amber-50 border border-amber-200 text-amber-800 rounded-lg px-3 py-2">
        Todavía no hay edición de Estados/Transiciones ya creados (renombrar, borrar) — sí se pueden agregar y guardar.
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-[1fr_380px] gap-4 items-start">
        <div class="space-y-4 min-w-0">
          <.panel_encabezado header_form={@header_form} iconos_sugeridos={@iconos_sugeridos} carpetas={@carpetas} />
          <.panel_campos campos={@campos} />
          <.tabla_estados estados={@estados} transiciones={@transiciones} puede_agregar={@completitud.tiene_campos} />
          <.tabla_transiciones transiciones={@transiciones} estados_por_id={@estados_por_id} catalogo={@header.schema_context_name}
            puede_agregar={@completitud.tiene_estados and @completitud.tiene_alta_o_inicial} />
        </div>
        <div class="lg:sticky lg:top-4">
          <.diagrama_transiciones diagrama={@diagrama} />
        </div>
      </div>
    </div>

    <.modal_regla :if={@regla_form} form={@regla_form} vocabulario={MetaEstadosAdmin.vocabulario()} />
    <.modal_campo :if={@campo_form} form={@campo_form} catalogos={@catalogos_referenciables} />
    <.modal_eliminar_campo :if={@eliminar_campo_form} form={@eliminar_campo_form} />
    <.modal_estado :if={@estado_form} form={@estado_form} iconos_sugeridos={@iconos_sugeridos} />
    <.modal_transicion :if={@transicion_form} form={@transicion_form} estados={@estados} campos={@campos} />
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
      Enum.map(estados, fn e -> ~s(    state "#{escapar_mermaid(e.nombre)}" as #{Map.fetch!(alias_por_id, e.id)}) end)

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
  defp pasos_motor(completitud, transiciones) do
    tiene_transiciones? = transiciones != [] and completitud.transiciones_self_loop_sin_campos_editables == 0

    [
      {"Campos", completitud.tiene_campos},
      {"Estados", completitud.tiene_estados},
      {"Estado inicial", completitud.tiene_alta_o_inicial},
      {"Transiciones", tiene_transiciones?},
      {"Reglas", completitud.reglas.negocio_stub == 0}
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
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Reglas</th>
                <th class="px-1.5 py-1 border-b border-gray-200"></th>
              </tr>
            </thead>
            <tbody>
              <%= for t <- @transiciones do %>
                <% self_loop? = t.estado_origen_id != nil and t.estado_origen_id == t.estado_destino_id %>
                <% aviso? = self_loop? and t.campos_editables == [] %>
                <% tiene_pre? = Enum.any?(t.reglas, &(&1.tipo == "pre")) %>
                <% tiene_post? = Enum.any?(t.reglas, &(&1.tipo == "post")) %>
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
                  <td class="px-1.5 py-1.5">
                    <div class="flex flex-wrap gap-1 mb-1.5">
                      <%= for r <- t.reglas do %>
                        <span
                          class={[
                            "inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[11px] font-mono",
                            r.tipo == "pre" && "bg-gray-100 text-gray-700",
                            r.tipo == "post" && "bg-purple-50 text-purple-700"
                          ]}
                          title={"#{r.tipo}: #{inspect(r.params)}"}
                        >
                          {r.regla}
                          <%= if MetaEstadosAdmin.stub_sin_completar?(@catalogo, r.regla) do %>
                            <span class="text-amber-600" title="Stub de andamiaje sin completar todavía">⏳</span>
                          <% end %>
                          <button
                            type="button"
                            phx-click="eliminar_regla"
                            phx-value-id={r.id}
                            data-confirm="¿Quitar esta regla de la transición?"
                            class="text-gray-400 hover:text-red-600 leading-none"
                          >×</button>
                        </span>
                      <% end %>
                    </div>

                    <div class="flex flex-wrap gap-2 text-[11px]">
                      <button
                        type="button"
                        phx-click="abrir_form_regla"
                        phx-value-transicion_id={t.id}
                        phx-value-accion={t.accion}
                        class="text-purple-700 hover:text-purple-900 font-semibold"
                      >+ Regla</button>

                      <%= if not tiene_pre? do %>
                        <button type="button" phx-click="andamiar_negocio" phx-value-transicion_id={t.id} phx-value-tipo="pre" class="text-gray-500 hover:text-gray-800 font-semibold">
                          + Negocio (pre)
                        </button>
                      <% end %>
                      <%= if not tiene_post? do %>
                        <button type="button" phx-click="andamiar_negocio" phx-value-transicion_id={t.id} phx-value-tipo="post" class="text-gray-500 hover:text-gray-800 font-semibold">
                          + Negocio (post)
                        </button>
                      <% end %>
                    </div>
                  </td>
                  <td class="px-1.5 py-1.5 whitespace-nowrap">
                    <button type="button" phx-click="abrir_editar_transicion" phx-value-id={t.id} class="text-blue-600 hover:text-blue-800 text-[11px] font-semibold mr-2">
                      Editar
                    </button>
                    <button type="button" phx-click="eliminar_transicion" phx-value-id={t.id}
                      data-confirm={"¿Eliminar la transición \"#{t.accion}\"? También se borran sus reglas."}
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

  attr :form, :map, required: true
  attr :vocabulario, :map, required: true

  defp modal_regla(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div class="bg-white rounded-xl shadow-lg max-w-sm w-full p-4 text-xs">
        <h2 class="text-sm font-bold text-gray-900 mb-1">Agregar regla</h2>
        <p class="text-gray-500 mb-3">
          Transición <span class="font-mono">{@form.accion}</span> — vocabulario cerrado
        </p>

        <%= if @form.error do %>
          <div class="bg-red-50 text-red-700 rounded-lg px-2 py-1.5 mb-2">{@form.error}</div>
        <% end %>

        <form phx-submit="guardar_regla">
          <label class="block font-medium text-gray-900 mb-1">Regla</label>
          <select name="regla" phx-change="elegir_regla" class="w-full border border-gray-300 rounded-lg px-2 py-1.5 mb-3 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500">
            <option value="">— Elegir —</option>
            <%= for {nombre, {tipo, _requeridos}} <- Enum.sort(@vocabulario) do %>
              <option value={nombre} selected={@form.regla == nombre}>{tipo} · {nombre}</option>
            <% end %>
          </select>

          <%= if @form.regla do %>
            <% {_tipo, requeridos} = Map.fetch!(@vocabulario, @form.regla) %>
            <div class="space-y-2 mb-3">
              <%= for campo <- requeridos do %>
                <.campo_param_regla regla={@form.regla} campo={campo} />
              <% end %>
            </div>
          <% end %>

          <div class="flex justify-end gap-2">
            <button type="button" phx-click="cerrar_form_regla" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
              Cancelar
            </button>
            <button type="submit" disabled={!@form.regla} class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 disabled:opacity-40 disabled:cursor-not-allowed">
              Guardar
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :regla, :string, required: true
  attr :campo, :string, required: true

  defp campo_param_regla(%{regla: "campo_cumple", campo: "operador"} = assigns) do
    ~H"""
    <div>
      <label class="block text-gray-700 mb-0.5">operador</label>
      <select name="params[operador]" class="w-full border border-gray-300 rounded-lg px-2 py-1">
        <option value=">">&gt;</option>
        <option value=">=">&gt;=</option>
        <option value="<">&lt;</option>
        <option value="<=">&lt;=</option>
        <option value="==">==</option>
        <option value="!=">!=</option>
      </select>
    </div>
    """
  end

  defp campo_param_regla(%{regla: "mutar_relacionados", campo: "cambio"} = assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-2">
      <div>
        <label class="block text-gray-700 mb-0.5">cambio: campo</label>
        <input type="text" name="params[cambio_campo]" class="w-full border border-gray-300 rounded-lg px-2 py-1" />
      </div>
      <div>
        <label class="block text-gray-700 mb-0.5">cambio: valor</label>
        <input type="text" name="params[cambio_valor]" class="w-full border border-gray-300 rounded-lg px-2 py-1" />
      </div>
    </div>
    """
  end

  defp campo_param_regla(%{campo: "campos"} = assigns) do
    ~H"""
    <div>
      <label class="block text-gray-700 mb-0.5">campos (separados por coma)</label>
      <input type="text" name="params[campos]" placeholder="campo_a, campo_b" class="w-full border border-gray-300 rounded-lg px-2 py-1" />
    </div>
    """
  end

  defp campo_param_regla(assigns) do
    ~H"""
    <div>
      <label class="block text-gray-700 mb-0.5">{@campo}</label>
      <input type="text" name={"params[#{@campo}]"} class="w-full border border-gray-300 rounded-lg px-2 py-1" />
    </div>
    """
  end

  @tipos_campo ~w(string integer decimal boolean date enum referencia)

  attr :form, :map, required: true
  attr :catalogos, :list, required: true

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
            <label class="block text-gray-700 mb-0.5">Nombre</label>
            <input type="text" name="nombre" value={@form["nombre"]} placeholder="pty_carro_color" required
              pattern="[a-z][a-z0-9_]*" maxlength="50"
              class="w-full border border-gray-300 rounded-lg px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />
          </div>
          <div>
            <label class="block text-gray-700 mb-0.5">Etiqueta</label>
            <input type="text" name="etiqueta" value={@form["etiqueta"]} required maxlength="100"
              class="w-full border border-gray-300 rounded-lg px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />
          </div>
          <div>
            <label class="block text-gray-700 mb-0.5">Tipo</label>
            <select name="tipo" class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
              <%= for tipo <- @tipos do %>
                <option value={tipo} selected={@form["tipo"] == tipo}>{tipo}</option>
              <% end %>
            </select>
          </div>
          <%= if @form["tipo"] == "referencia" do %>
            <div>
              <label class="block text-gray-700 mb-0.5">Catálogo destino</label>
              <select name="catalogo" class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
                <option value="">— Elegir —</option>
                <%= for c <- @catalogos do %>
                  <option value={c.nombre} selected={@form["catalogo"] == c.nombre}>{c.etiqueta}</option>
                <% end %>
              </select>
            </div>
          <% end %>
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
  attr :iconos_sugeridos, :list, required: true

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

          <div>
            <label class="block text-gray-700 mb-0.5">Ícono</label>
            <input type="hidden" name="icono" value={@form["icono"]} />
            <button type="button" phx-click={JS.toggle(to: "#selector-iconos-estado")}
              class="w-6 h-6 flex items-center justify-center border border-gray-300 rounded-lg bg-gray-50 hover:bg-gray-100 text-gray-700" title="Elegir ícono">
              <%= if @form["icono"] not in [nil, ""] do %>
                <span class="material-symbols-outlined" style="font-size: 16px">{@form["icono"]}</span>
              <% else %>
                <span class="material-symbols-outlined text-gray-400" style="font-size: 16px">apps</span>
              <% end %>
            </button>
            <div id="selector-iconos-estado" class="hidden mt-1 border border-gray-200 rounded-lg bg-white shadow-lg p-1.5 max-w-md">
              <div class="grid grid-cols-10 gap-0.5 max-h-40 overflow-y-auto">
                <%= for icono <- @iconos_sugeridos do %>
                  <button type="button" title={icono}
                    phx-click={JS.push("elegir_icono_estado", value: %{icono: icono}) |> JS.hide(to: "#selector-iconos-estado")}
                    class={[
                      "w-6 h-6 flex items-center justify-center rounded-lg text-gray-700 hover:bg-purple-50 hover:text-purple-700",
                      @form["icono"] == icono && "bg-purple-100 text-purple-700"
                    ]}>
                    <span class="material-symbols-outlined" style="font-size: 16px">{icono}</span>
                  </button>
                <% end %>
              </div>
            </div>
          </div>

          <label class="flex items-center gap-1.5">
            <input type="hidden" name="es_inicial" value="false" />
            <input type="checkbox" name="es_inicial" value="true" checked={@form["es_inicial"] == true} class="accent-purple-600" />
            Es el estado inicial
          </label>

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

  defp modal_transicion(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div class="bg-white rounded-xl shadow-lg max-w-sm w-full p-4 text-xs">
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

          <%= if @campos != [] do %>
            <div>
              <label class="block text-gray-700 mb-1">Campos editables en esta transición</label>
              <div class="flex flex-col gap-1 max-h-48 overflow-y-auto border border-gray-200 rounded-lg p-1.5">
                <%= for c <- @campos do %>
                  <label class="flex items-center gap-1">
                    <input type="checkbox" name="campos_editables[]" value={c.schema_context_field}
                      checked={c.schema_context_field in (@form["campos_editables"] || [])} class="accent-purple-600" />
                    <span class="font-mono truncate">{c.schema_context_field}</span>
                  </label>
                <% end %>
              </div>
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
end
