defmodule MetadataAppWeb.Sysadmin.BcListLive do
  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_bc", "leer"}}

  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerador
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaEstadosAdmin
  alias MetadataApp.MetaConsultas
  alias MetadataApp.MetaPublicador
  alias MetadataAppWeb.AdminNav
  alias MetadataAppWeb.AuditoriaContexto
  alias Phoenix.LiveView.JS

  @topic "bc_contextos"
  @por_pagina 30

  # Mismo subconjunto curado de Material Symbols de siempre — los modales
  # "Nueva carpeta" y "Editar carpeta" viven acá adentro (ver
  # abrir_form_carpeta/3 y abrir_editar_carpeta/3), así que el listado
  # viaja con ellos.
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

  # Menú hardcodeado del perfil sysadmin — todavía no hay login, así que
  # esta pantalla es de acceso directo. Según se agreguen secciones, se
  # suman aquí (por ahora solo "BC List").
  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"},
    %{tipo: :pagina, id: "buscar_trn", label: "Buscar TRN", nav: "/sysadmin/buscar-trn"},
    %{tipo: :pagina, id: "tepache", label: "Tepache Exp/Imp", nav: "/sysadmin/tepache"},
    %{tipo: :pagina, id: "roles", label: "Roles y Usuarios", nav: "/sysadmin/roles"},
    %{tipo: :pagina, id: "usuarios_empresa", label: "Usuarios", nav: "/sysadmin/usuarios"},
    %{tipo: :pagina, id: "credenciales", label: "Credenciales", nav: "/sysadmin/credenciales"},
    %{tipo: :pagina, id: "ambientes", label: "Ambientes de Deploy", nav: "/sysadmin/ambientes"},
    %{tipo: :pagina, id: "acciones_externas", label: "Acciones externas", nav: "/sysadmin/acciones-externas"},
    %{tipo: :pagina, id: "jerarquia", label: "Jerarquía organizacional", nav: "/sysadmin/jerarquia"},
  %{tipo: :pagina, id: "panel_control", label: "Panel Control", nav: "/sysadmin/panel-control"}
  ]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(MetadataApp.PubSub, @topic)

    {:ok,
     socket
     |> assign(:current_page, "bc_list")
     |> assign(:menu_items, @menu)
     |> assign(:sidebar_open, false)
     |> assign(:show_programacion_children, false)
     |> assign(:show_clientes_children, false)


     |> assign(:show_prettycore_children, false)
     |> assign(:busqueda, "")
     |> assign(:pagina, 1)
     # get_connect_info/2 solo existe durante mount/3 -- se calcula UNA vez
     # acá y se guarda en assigns para que confirmar_eliminar/eliminar_campo
     # lo reuse (roadmap #13, ver AuditoriaContexto.desde_socket/1).
     |> assign(:contexto_auditoria, AuditoriaContexto.desde_socket(socket))
     # Set de rutas EXPANDIDAS (opt-in), no colapsadas — así el estado por
     # default (MapSet vacío, sin nada marcado) significa "todo cerrado",
     # tanto al entrar por primera vez como después de reiniciar el
     # navegador (esto es puro estado de socket, nunca se persiste).
     |> assign(:carpetas_expandidas, MapSet.new())
     |> assign(:editando_orden, false)
     |> assign(:carpeta_editando_orden, nil)
     |> assign(:accion_eliminar, nil)
     |> assign(:seleccionados, MapSet.new())
     |> assign(:wizard_publicar, nil)
     |> assign(:carpeta_form, nil)
     |> assign(:carpeta_error, nil)
     |> assign(:carpetas_disponibles, [])
     |> assign(:carpeta_editar, nil)
     |> assign(:carpeta_editar_error, nil)
     |> assign(:consulta_form, nil)
     |> assign(:consulta_error, nil)
     |> assign(:catalogos_base_disponibles, [])
     |> assign(:tablas_relacionadas, [])
     |> assign(:selector_tabla_relacionada_abierto, false)
     |> assign(:catalogos_relacionables_disponibles, [])
     |> assign(:union_manual, nil)
     |> cargar_headers()}
  end

  def handle_event("change_page", %{"id" => id}, socket) do
    AdminNav.handle_nav(id, socket, "bc_list")
  end

  # Cada búsqueda nueva arranca desde la página 1 — si no, podrías quedar
  # parado en una página que ya ni existe con los resultados filtrados.
  def handle_event("buscar", %{"value" => valor}, socket) do
    {:noreply, socket |> assign(:busqueda, valor) |> assign(:pagina, 1) |> cargar_headers()}
  end

  def handle_event("pagina_anterior", _params, socket) do
    {:noreply, socket |> assign(:pagina, max(socket.assigns.pagina - 1, 1)) |> cargar_headers()}
  end

  def handle_event("pagina_siguiente", _params, socket) do
    {:noreply, socket |> assign(:pagina, socket.assigns.pagina + 1) |> cargar_headers()}
  end

  # Colapsar/expandir un grupo de la tabla — estado solo de esta pantalla
  # (no se guarda en el servidor entre sesiones, se resetea al recargar).
  def handle_event("toggle_carpeta", %{"ruta" => ruta}, socket) do
    expandidas = socket.assigns.carpetas_expandidas

    expandidas =
      if MapSet.member?(expandidas, ruta) do
        MapSet.delete(expandidas, ruta)
      else
        MapSet.put(expandidas, ruta)
      end

    {:noreply, assign(socket, :carpetas_expandidas, expandidas)}
  end

  # --- Editar vista: reordenar carpetas raíz por drag-and-drop -----------------
  # Mismo hook ListaOrdenable que ya usa PlantillaConstructorLive (Sortable.js
  # por debajo) — acá no hace falta el "group" compartido que usa ese otro
  # editor para arrastrar ENTRE contenedores anidados, porque acá hay un
  # único contenedor plano (las carpetas raíz de esta página), así que se
  # reusa tal cual sin tocar el JS.
  def handle_event("abrir_editar_orden", _params, socket) do
    {:noreply, socket |> assign(:editando_orden, true) |> assign(:carpeta_editando_orden, nil)}
  end

  # Igual que "abrir_editar_orden", pero acotado a UNA carpeta madre —
  # botón "Vista" propio en cada fila de carpeta raíz (ver filas_arbol/1).
  def handle_event("abrir_editar_orden_carpeta", %{"clave" => clave}, socket) do
    {:noreply, socket |> assign(:editando_orden, true) |> assign(:carpeta_editando_orden, clave)}
  end

  def handle_event("cerrar_editar_orden", _params, socket) do
    {:noreply, socket |> assign(:editando_orden, false) |> assign(:carpeta_editando_orden, nil)}
  end

  # Recalcula el orden completo de los hermanos visibles en este
  # contenedor (no solo el que se movió) a partir de su posición ANTERIOR
  # + la nueva posición que ya calculó Sortable.js del lado del cliente —
  # así después de cada suelte queda una secuencia 0..N-1 totalmente
  # definida, sin mezclar "algunos con orden manual, otros sin" que
  # complicaría el criterio de desempate. Cada hermano se identifica por
  # su CLAVE (clave_de_carpeta/2 — id real, o "ruta:..." si es una
  # carpeta implícita sin Header propio), nunca por `.id` a secas: una
  # carpeta implícita también tiene que poder reordenarse entre sus
  # hermanas, y reordenar_hermanos/1 ya sabe persistir ambos tipos.
  def handle_event("mover_a", %{"id" => id, "contenedor_id" => contenedor_id, "index" => index}, socket) do
    {hijos_actuales, ruta_hijos} = hijos_de(socket.assigns.arbol, contenedor_id) || {[], ""}
    claves_actuales = Enum.map(hijos_actuales, &clave_de_carpeta(&1, ruta_hijos))
    nuevo_orden = claves_actuales |> List.delete(id) |> List.insert_at(index, id)

    :ok = MetaSchemaContext.reordenar_hermanos(nuevo_orden)

    {:noreply, cargar_headers(socket)}
  end

  # Paso 1 del borrado: consulta el impacto antes de mostrar cualquier
  # confirmación. Si hay dependientes, el borrado real va a fallar seguro
  # (validar_sin_dependientes en CatalogoGenerador.eliminar/3) — se corta acá
  # con un mensaje explicativo en vez de dejar avanzar a un confirm que
  # después explota.
  def handle_event("pedir_eliminar", %{"tabla" => tabla, "label" => label}, socket) do
    case CatalogoGenerador.impacto(tabla) do
      {:ok, %{dependientes: []} = resultado} ->
        {:noreply,
         assign(socket, :accion_eliminar, %{
           tipo: :confirmar,
           tabla: tabla,
           label: label,
           filas: resultado.filas,
           confirmar_texto: ""
         })}

      {:ok, %{dependientes: dependientes}} ->
        {:noreply,
         assign(socket, :accion_eliminar, %{
           tipo: :bloqueado,
           tabla: tabla,
           label: label,
           dependientes: dependientes
         })}

      {:error, _motivo} ->
        {:noreply, put_flash(socket, :error, "No se pudo consultar el catálogo #{tabla}.")}
    end
  end

  # Mismo motivo que "cancelar_wizard_publicar" con procesando?:true: no
  # dejar cerrar el modal mientras el despublicar está en vuelo (armando
  # bundle, llamadas de red a GitHub) -- cerrar acá no cancela el Task, solo
  # perdería la referencia visual a que sigue corriendo.
  def handle_event("cancelar_eliminar", _params, %{assigns: %{accion_eliminar: %{tipo: :despublicar, procesando?: true}}} = socket),
    do: {:noreply, socket}

  def handle_event("cancelar_eliminar", _params, socket) do
    {:noreply, assign(socket, :accion_eliminar, nil)}
  end

  # Contraparte de "confirmar_publicar" para un catálogo pty_*/demo100_* ya
  # borrado local -- reutiliza los mismos MetaPublicador.armar_bundle/
  # persistir_bundle/disparar_deploy que mix motor.despublicar (y que
  # "Publicar"), solo que acá ya no queda .ex/meta/motor/reglas del
  # catálogo (se borraron con "Eliminar" de recién) -- lo único que
  # armar_bundle/1 encuentra es la migración de DROP, que es justo lo que
  # tiene que viajar. start_async/3 por el mismo motivo que publicar_paquete:
  # tarda unos segundos de verdad (tar, red), no bloquear el proceso LiveView.
  def handle_event("confirmar_despublicar", _params, socket) do
    %{tabla: tabla} = socket.assigns.accion_eliminar

    socket =
      socket
      |> update(:accion_eliminar, &Map.merge(&1, %{procesando?: true, error: nil}))
      |> start_async(:despublicar_catalogo, fn -> despublicar_catalogo(tabla) end)

    {:noreply, socket}
  end

  # Una carpeta no tiene tabla ni filas que perder — a diferencia de
  # "pedir_eliminar" (archivo), acá no hay que consultar impacto/1 primero.
  # Pero si tiene algo debajo (otra carpeta o un catálogo) no se deja seguir:
  # el botón ya viene oculto en filas_arbol/1 cuando nodo.hijos != [], esta
  # revalidación es por si el árbol que tiene el cliente quedó desactualizado
  # (otra pestaña agregó un hijo después de que se pintó esta pantalla) y el
  # link "Eliminar" seguía ahí en memoria.
  def handle_event("pedir_eliminar_carpeta", %{"nombre" => nombre, "label" => label}, socket) do
    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        {:noreply, put_flash(socket, :error, "Esa carpeta ya no existe.")}

      header ->
        if MetaSchemaContext.tiene_hijos_en_nav?(header.schema_context_nav) do
          {:noreply,
           put_flash(
             socket,
             :error,
             "No se puede eliminar '#{label}': todavía tiene carpetas o catálogos adentro. Muévelos o bórralos primero."
           )}
        else
          {:noreply, assign(socket, :accion_eliminar, %{tipo: :confirmar_carpeta, nombre: nombre, label: label})}
        end
    end
  end

  def handle_event("confirmar_eliminar_carpeta", _params, socket) do
    %{nombre: nombre} = socket.assigns.accion_eliminar

    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        {:noreply,
         socket
         |> assign(:accion_eliminar, nil)
         |> put_flash(:error, "Esa carpeta ya no existe.")}

      # Mismo chequeo que en "pedir_eliminar_carpeta", repetido acá porque
      # puede pasar tiempo entre abrir el modal de confirmación y darle
      # click a "Eliminar" — si en el medio alguien agregó un hijo, no debe
      # colarse el borrado solo porque ya había pasado el primer chequeo.
      header ->
        if MetaSchemaContext.tiene_hijos_en_nav?(header.schema_context_nav) do
          {:noreply,
           socket
           |> assign(:accion_eliminar, nil)
           |> put_flash(
             :error,
             "No se puede eliminar '#{header.schema_context_label}': todavía tiene carpetas o catálogos adentro."
           )}
        else
          case MetaSchemaContext.eliminar_header(header) do
            :ok ->
              {:noreply,
               socket
               |> assign(:accion_eliminar, nil)
               |> put_flash(:info, "Carpeta #{header.schema_context_label} eliminada.")
               |> cargar_headers()}

            {:error, motivo} ->
              {:noreply,
               socket
               |> assign(:accion_eliminar, nil)
               |> put_flash(:error, "No se pudo eliminar: #{inspect(motivo)}")}
          end
        end
    end
  end

  # Una Consulta (schema_context_type: 3) tampoco tiene tabla física propia
  # (a diferencia de "pedir_eliminar", nunca se llama a
  # CatalogoGenerador.impacto/1 acá — reventaría con "relation does not
  # exist" contra un nombre que no es una tabla real) — mismo criterio de
  # confirmación simple de una carpeta, no el de "escribe el nombre exacto"
  # de un catálogo con datos reales que perder.
  def handle_event("pedir_eliminar_consulta", %{"nombre" => nombre, "label" => label}, socket) do
    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        {:noreply, put_flash(socket, :error, "Esa consulta ya no existe.")}

      _header ->
        {:noreply, assign(socket, :accion_eliminar, %{tipo: :confirmar_consulta, nombre: nombre, label: label})}
    end
  end

  def handle_event("confirmar_eliminar_consulta", _params, socket) do
    %{nombre: nombre} = socket.assigns.accion_eliminar

    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        {:noreply,
         socket
         |> assign(:accion_eliminar, nil)
         |> put_flash(:error, "Esa consulta ya no existe.")}

      header ->
        case MetaSchemaContext.eliminar_header(header) do
          :ok ->
            {:noreply,
             socket
             |> assign(:accion_eliminar, nil)
             |> put_flash(:info, "Consulta #{header.schema_context_label} eliminada.")
             |> cargar_headers()}

          {:error, motivo} ->
            {:noreply,
             socket
             |> assign(:accion_eliminar, nil)
             |> put_flash(:error, "No se pudo eliminar: #{inspect(motivo)}")}
        end
    end
  end

  # Borrar un catálogo (Business Process) sí es de alto impacto — es un
  # DELETE físico de la tabla completa (ver CatalogoGenerador.eliminar/3),
  # a diferencia de una carpeta (que solo pierde su etiqueta/ícono). Por eso
  # acá, y no en el borrado de carpetas, es donde pedimos teclear el nombre
  # exacto antes de habilitar "Eliminar" — solo actualiza lo que se compara
  # en el modal, no toca nada en la base todavía.
  def handle_event("escribir_confirmacion_eliminar", %{"value" => texto}, socket) do
    {:noreply, update(socket, :accion_eliminar, &Map.put(&1, :confirmar_texto, texto))}
  end

  # confirmar_filas viaja como el número ya conocido del paso de impacto (no
  # se le vuelve a pedir al usuario que lo tipee) — sigue siendo una
  # confirmación real porque valida contra el conteo actual en el momento del
  # borrado, no el de cuando se abrió el modal.
  def handle_event("confirmar_eliminar", _params, socket) do
    %{tabla: tabla, filas: filas, confirmar_texto: confirmar_texto} = socket.assigns.accion_eliminar

    if confirmar_texto != tabla do
      # No debería pasar (el botón viene disabled hasta que coincida), pero
      # el atributo disabled es solo del lado del cliente — sin este chequeo,
      # alguien podría mandar el evento igual saltándoselo.
      {:noreply, put_flash(socket, :error, "El texto no coincide con el nombre del catálogo.")}
    else
      case CatalogoGenerador.eliminar(tabla, tabla, filas, socket.assigns.contexto_auditoria) do
        {:ok, _resultado} ->
          {:noreply,
           socket
           |> assign(:accion_eliminar, siguiente_paso_tras_eliminar(tabla, socket.assigns.accion_eliminar.label))
           |> put_flash(:info, "Catálogo #{tabla} eliminado.")
           |> cargar_headers()}

        {:error, motivo} ->
          {:noreply,
           socket
           |> assign(:accion_eliminar, nil)
           |> put_flash(:error, "No se pudo eliminar #{tabla}: #{inspect(motivo)}")}
      end
    end
  end

  # Un catálogo pty_*/demo100_* nunca pasa por git (.gitignore, ver
  # docs/roadmap.md #7) -- ni su .ex, ni sus migraciones, ni su borrado.
  # commit/push no alcanza para que esto llegue a producción, así que acá
  # mismo se ofrece el paso siguiente ("despublicar", mix motor.despublicar
  # equivalente en la UI) en vez de dejarlo como un pendiente invisible.
  # Un catálogo normal SÍ sincroniza solo por el pipeline de git+CI de
  # siempre -- no necesita este paso.
  defp siguiente_paso_tras_eliminar(tabla, label) do
    if String.starts_with?(tabla, "pty_") or String.starts_with?(tabla, "demo100_") do
      %{tipo: :despublicar, tabla: tabla, label: label, procesando?: false, error: nil}
    end
  end

  # El botón "Despliegue" individual (exportaba .meta.json/.motor.json a
  # disco, sin publicar nada) se sacó el 2026-07-24 al llegar el wizard de
  # publicación: regenerar_paquete/1 + exportar_paquete/1, más abajo, ya
  # hacen exactamente esto para el paquete completo como parte de publicar
  # de verdad — mantener las dos acciones por separado solo generaba
  # confusión (un botón que decía "Despliegue" pero nunca desplegaba nada).

  # Selección para el wizard de publicación (multi-catálogo) — checkbox por
  # fila, solo disponible donde adjuntar_puede_desplegar/1 marcó el
  # catálogo como listo (real, completo, válido, compilado).
  def handle_event("toggle_seleccion", %{"tabla" => tabla}, socket) do
    seleccionados =
      if MapSet.member?(socket.assigns.seleccionados, tabla) do
        MapSet.delete(socket.assigns.seleccionados, tabla)
      else
        MapSet.put(socket.assigns.seleccionados, tabla)
      end

    {:noreply, assign(socket, :seleccionados, seleccionados)}
  end

  # Paso 1 del wizard: calcula el paquete completo (detalles + cierre de
  # referencias, ya en orden) de todo lo seleccionado y lo muestra de solo
  # lectura antes de tocar nada — mismo espíritu que "pedir_eliminar"
  # (consultar impacto antes de confirmar), pero acá el "impacto" es qué se
  # va a publicar y en qué orden.
  def handle_event("abrir_wizard_publicar", _params, socket) do
    nombres = socket.assigns.seleccionados |> MapSet.to_list() |> Enum.sort()

    case MetaPublicador.validar(nombres) do
      {:ok, %{catalogos: catalogos, problemas: problemas}} ->
        {:noreply,
         assign(socket, :wizard_publicar, %{
           seleccionados: nombres,
           catalogos: catalogos,
           problemas: problemas,
           error: nil,
           procesando?: false
         })}

      {:error, mensaje} ->
        {:noreply, put_flash(socket, :error, mensaje)}
    end
  end

  # Ignorado mientras se está publicando (defensa en profundidad — el botón
  # ya desaparece del modal en ese estado, esto cubre un click que haya
  # quedado en cola de antes): cerrar el modal a mitad de un publicar_paquete/2
  # ya disparado no lo cancela (sigue corriendo en el Task de
  # start_async/3 de abajo), solo le haría perder al usuario la pantalla
  # de "Procesando" — justo lo que no quiere.
  def handle_event("cancelar_wizard_publicar", _params, %{assigns: %{wizard_publicar: %{procesando?: true}}} = socket),
    do: {:noreply, socket}

  def handle_event("cancelar_wizard_publicar", _params, socket) do
    {:noreply, assign(socket, :wizard_publicar, nil)}
  end

  # Paso 2 (confirmar): re-sincroniza cada schema contra la metadata actual
  # (mismo criterio que mix gen.catalogos, self-heal si algo quedó
  # desactualizado — ver el bug real del 2026-07-23 documentado en
  # CatalogoGenerador.generar/1), exporta metadata+autómata, arma el bundle
  # y dispara bc-deploy.yml. Todo o nada: si algo falla, el error queda en
  # el modal en vez de cerrarse solo.
  #
  # start_async/3 (no una llamada síncrona directa) a propósito, 2026-08-06
  # a pedido explícito: publicar_paquete/2 tarda unos segundos de verdad
  # (tar, llamadas de red a GitHub) — corrido síncrono, el proceso de la
  # LiveView queda bloqueado y un doble-click en el botón encolaba un
  # SEGUNDO publish. Con start_async/3 el primer click marca
  # procesando?:true y repinta el modal (spinner, sin botones) ANTES de
  # que arranque el trabajo lento, así ya no hay botón que doble-clickear.
  def handle_event("confirmar_publicar", _params, socket) do
    %{seleccionados: seleccionados, catalogos: catalogos} = socket.assigns.wizard_publicar

    socket =
      socket
      |> update(:wizard_publicar, &Map.merge(&1, %{procesando?: true, error: nil}))
      |> start_async(:publicar_paquete, fn -> publicar_paquete(seleccionados, catalogos) end)

    {:noreply, socket}
  end

  # "Nueva carpeta" — antes vivía en BcNuevoLive, una ventana emergente
  # aparte (window.open). Ahora es un modal interno, igual que
  # modal_estado/modal_transicion en BcMotorLive: nada de navegar a otra
  # página ni abrir otra ventana del navegador.
  def handle_event("abrir_form_carpeta", _params, socket) do
    {:noreply,
     socket
     |> assign(:carpetas_disponibles, MetaSchemaContext.listar_carpetas_existentes())
     |> assign(:carpeta_form, formulario_carpeta_vacio())
     |> assign(:carpeta_error, nil)}
  end

  def handle_event("cerrar_form_carpeta", _params, socket) do
    {:noreply, socket |> assign(:carpeta_form, nil) |> assign(:carpeta_error, nil)}
  end

  # Sin esto el servidor nunca se entera de lo tecleado hasta el submit —
  # cualquier vuelta al servidor antes de eso repinta el formulario con los
  # valores viejos y borra lo escrito.
  def handle_event("validar_carpeta", %{"contexto" => contexto}, socket) do
    contexto =
      contexto
      |> Map.put("visible", contexto["visible"] == "true")
      |> Map.put("nav_final", normalizar_slug_carpeta(contexto["nav_final"]))
      |> Map.put("icono", normalizar_icono_carpeta(contexto["icono"]))

    nav = componer_nav_carpeta(contexto["carpeta_padre"], contexto["nav_final"])

    error =
      if nav != "" and MetaSchemaContext.obtener_header_por_nav(nav) do
        "Esa ruta ya la usa otro catálogo o carpeta."
      end

    {:noreply,
     socket
     |> assign(:carpeta_form, contexto)
     |> assign(:carpeta_error, error)}
  end

  def handle_event("elegir_icono_carpeta", %{"icono" => icono}, socket) do
    {:noreply, update(socket, :carpeta_form, &Map.put(&1, "icono", icono))}
  end

  def handle_event("guardar_carpeta", %{"contexto" => contexto}, socket) do
    contexto =
      contexto
      |> Map.put("nav", componer_nav_carpeta(contexto["carpeta_padre"], contexto["nav_final"]))
      |> then(&Map.put(&1, "nombre", nombre_desde_nav_carpeta(&1["nav"])))

    case validar_formulario_carpeta(contexto) do
      :ok ->
        header_attrs = %{
          "schema_context_name" => contexto["nombre"],
          "schema_context_label" => contexto["etiqueta"],
          "schema_context_nav" => contexto["nav"],
          "schema_visible" => contexto["visible"] == "true",
          "schema_context_type" => 2,
          "schema_context_icono" => nil_si_vacio_carpeta(normalizar_icono_carpeta(contexto["icono"])),
          "detalles" => []
        }

        case MetaSchemaContext.crear_header_con_detalles(header_attrs) do
          {:ok, {header, _detalles}} ->
            Phoenix.PubSub.broadcast(MetadataApp.PubSub, @topic, {:bc_creado, header})

            {:noreply,
             socket
             |> assign(:carpeta_form, nil)
             |> assign(:carpeta_error, nil)
             |> put_flash(:info, "Carpeta '#{header.schema_context_label}' guardada.")
             |> cargar_headers()}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:carpeta_form, contexto)
             |> assign(:carpeta_error, resumen_errores_carpeta(changeset))}
        end

      {:error, motivo} ->
        {:noreply,
         socket
         |> assign(:carpeta_form, contexto)
         |> assign(:carpeta_error, motivo)}
    end
  end

  # "Nueva consulta" (BC tipo 3, "Consulta Ecto") — mismo patrón de modal
  # interno que "Nueva carpeta", con un campo extra (catálogo base). Sin
  # wizard de campos/estados: MetaConsultas.crear/2 auto-puebla `campos`
  # con TODO el contrato del catálogo elegido, se recorta después desde
  # el editor de la consulta.
  def handle_event("abrir_form_consulta", _params, socket) do
    {:noreply,
     socket
     |> assign(:carpetas_disponibles, MetaSchemaContext.listar_carpetas_existentes())
     |> assign(:catalogos_base_disponibles, MetaSchemaContext.listar_catalogos_referenciables())
     |> assign(:consulta_form, formulario_consulta_vacio())
     |> assign(:consulta_error, nil)
     |> assign(:tablas_relacionadas, [])
     |> assign(:selector_tabla_relacionada_abierto, false)
     |> assign(:union_manual, nil)}
  end

  def handle_event("cerrar_form_consulta", _params, socket) do
    {:noreply,
     socket
     |> assign(:consulta_form, nil)
     |> assign(:consulta_error, nil)
     |> assign(:tablas_relacionadas, [])
     |> assign(:selector_tabla_relacionada_abierto, false)
     |> assign(:union_manual, nil)}
  end

  # --- Consulta Ecto: agregar tablas relacionadas (Fase 2, joins) --------------
  # Todo esto vive en @tablas_relacionadas, un assign APARTE de
  # @consulta_form a propósito: "validar_consulta" reemplaza @consulta_form
  # entero con lo que manda el navegador en cada phx-change del formulario
  # (etiqueta/nav/catálogo base), y esos campos nunca incluyen las tablas
  # relacionadas (se arman con botones, no hay <input> para ellas) — si
  # vivieran adentro de @consulta_form, cualquier tecla tipeada en
  # "Etiqueta" las borraría sin que nadie lo pidiera.

  def handle_event("abrir_selector_tabla_relacionada", _params, socket) do
    ya_elegidos = [socket.assigns.consulta_form["catalogo_base"] | Enum.map(socket.assigns.tablas_relacionadas, & &1["catalogo"])]

    disponibles =
      MetaSchemaContext.listar_catalogos_referenciables()
      |> Enum.reject(&(&1.nombre in ya_elegidos))

    {:noreply,
     socket
     |> assign(:catalogos_relacionables_disponibles, disponibles)
     |> assign(:selector_tabla_relacionada_abierto, true)}
  end

  def handle_event("cerrar_selector_tabla_relacionada", _params, socket) do
    {:noreply, assign(socket, :selector_tabla_relacionada_abierto, false)}
  end

  def handle_event("agregar_tabla_relacionada", %{"catalogo" => catalogo}, socket) do
    catalogos_actuales = [socket.assigns.consulta_form["catalogo_base"] | Enum.map(socket.assigns.tablas_relacionadas, & &1["catalogo"])]

    fila =
      case MetaConsultas.detectar_union(catalogos_actuales, catalogo) do
        {:ok, union} -> Map.merge(union, %{"catalogo" => catalogo, "sin_union" => false})
        :sin_union -> %{"catalogo" => catalogo, "sin_union" => true}
      end
      |> Map.put("maestro_detalle", MetaConsultas.maestro_de_detalle(catalogo))

    {:noreply,
     socket
     |> update(:tablas_relacionadas, &(&1 ++ [fila]))
     |> assign(:selector_tabla_relacionada_abierto, false)}
  end

  # Solo se puede quitar la ÚLTIMA — si una tabla del medio ya se usó
  # como destino de una unión posterior, quitarla dejaría esa unión
  # apuntando a una tabla que ya no está. Mismo criterio que
  # MetaConsultas.quitar_ultima_tabla/1 del lado persistido.
  def handle_event("quitar_ultima_tabla_relacionada", _params, socket) do
    {:noreply, update(socket, :tablas_relacionadas, &List.delete_at(&1, -1))}
  end

  def handle_event("abrir_union_manual", %{"indice" => indice}, socket) do
    indice = String.to_integer(indice)
    fila = Enum.at(socket.assigns.tablas_relacionadas, indice)
    catalogos_previos = [socket.assigns.consulta_form["catalogo_base"] | Enum.map(Enum.take(socket.assigns.tablas_relacionadas, indice), & &1["catalogo"])]

    opciones_destino =
      for catalogo <- catalogos_previos, campo <- MetaConsultas.campos_disponibles_para_union(catalogo) do
        {catalogo, campo}
      end

    campos_nuevo = MetaConsultas.campos_disponibles_para_union(fila["catalogo"])

    {:noreply,
     assign(socket, :union_manual, %{
       indice: indice,
       catalogo: fila["catalogo"],
       campos_nuevo: campos_nuevo,
       campo_en_nuevo_elegido: List.first(campos_nuevo),
       maestro_detalle: MetaConsultas.maestro_de_detalle(fila["catalogo"]),
       opciones_destino: opciones_destino
     })}
  end

  def handle_event("cerrar_union_manual", _params, socket) do
    {:noreply, assign(socket, :union_manual, nil)}
  end

  # Guardrail (R3, bug real 2026-08-26): "id" es prácticamente siempre un
  # error para unir una tabla detalle -- avisa en vivo mientras se elige,
  # sin bloquear el submit (el admin puede tener un motivo real, aunque
  # rarísimo). No hace falta re-detectar nada acá -- maestro_detalle ya
  # quedó calculado al abrir el modal, es fijo por catálogo.
  def handle_event("cambiar_campo_union_manual", %{"campo_en_nuevo" => campo}, socket) do
    {:noreply, update(socket, :union_manual, &Map.put(&1, :campo_en_nuevo_elegido, campo))}
  end

  def handle_event("guardar_union_manual", %{"campo_en_nuevo" => campo_en_nuevo, "destino" => destino}, socket) do
    %{indice: indice} = socket.assigns.union_manual
    [catalogo_destino, campo_en_destino] = String.split(destino, ":", parts: 2)

    tablas =
      List.update_at(socket.assigns.tablas_relacionadas, indice, fn fila ->
        Map.merge(fila, %{
          "campo_en_nuevo" => campo_en_nuevo,
          "catalogo_destino" => catalogo_destino,
          "campo_en_destino" => campo_en_destino,
          "sin_union" => false
        })
      end)

    {:noreply, socket |> assign(:tablas_relacionadas, tablas) |> assign(:union_manual, nil)}
  end

  def handle_event("validar_consulta", %{"contexto" => contexto}, socket) do
    contexto = Map.put(contexto, "nav_final", normalizar_slug_carpeta(contexto["nav_final"]))
    nav = componer_nav_carpeta(contexto["carpeta_padre"], contexto["nav_final"])

    error =
      if nav != "" and MetaSchemaContext.obtener_header_por_nav(nav) do
        "Esa ruta ya la usa otro catálogo o carpeta."
      end

    {:noreply, socket |> assign(:consulta_form, contexto) |> assign(:consulta_error, error)}
  end

  def handle_event("guardar_consulta", %{"contexto" => contexto}, socket) do
    nav = componer_nav_carpeta(contexto["carpeta_padre"], contexto["nav_final"])
    nombre = nombre_desde_nav_consulta(nav)

    cond do
      contexto["catalogo_base"] in [nil, ""] ->
        {:noreply,
         socket |> assign(:consulta_form, contexto) |> assign(:consulta_error, "Elegí el catálogo base de la consulta.")}

      nombre == "" or String.trim(contexto["etiqueta"] || "") == "" ->
        {:noreply,
         socket
         |> assign(:consulta_form, contexto)
         |> assign(:consulta_error, "Completá etiqueta y navegación antes de guardar.")}

      MetaSchemaContext.obtener_header_por_nav(nav) ->
        {:noreply,
         socket |> assign(:consulta_form, contexto) |> assign(:consulta_error, "Esa ruta ya la usa otro catálogo o carpeta.")}

      Enum.any?(socket.assigns.tablas_relacionadas, & &1["sin_union"]) ->
        {:noreply,
         socket
         |> assign(:consulta_form, contexto)
         |> assign(:consulta_error, "Definí la unión de todas las tablas relacionadas antes de guardar.")}

      true ->
        header_attrs = %{
          "schema_context_name" => nombre,
          "schema_context_label" => contexto["etiqueta"],
          "schema_context_nav" => nav,
          "schema_visible" => true,
          "schema_context_type" => 3,
          "detalles" => []
        }

        with {:ok, {header, _detalles}} <- MetaSchemaContext.crear_header_con_detalles(header_attrs),
             {:ok, consulta} <- MetaConsultas.crear(header, contexto["catalogo_base"]),
             {:ok, _consulta} <- agregar_tablas_relacionadas(consulta, socket.assigns.tablas_relacionadas) do
          Phoenix.PubSub.broadcast(MetadataApp.PubSub, @topic, {:bc_creado, header})

          {:noreply,
           socket
           |> assign(:consulta_form, nil)
           |> assign(:consulta_error, nil)
           |> assign(:tablas_relacionadas, [])
           |> put_flash(:info, "Consulta '#{header.schema_context_label}' creada.")
           |> cargar_headers()}
        else
          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket |> assign(:consulta_form, contexto) |> assign(:consulta_error, resumen_errores_carpeta(changeset))}
        end
    end
  end

  # "Editar carpeta" — mismo cambio que "Nueva carpeta": antes era
  # BcEditarCarpetaLive en ventana emergente, ahora es un modal interno acá
  # mismo. Solo etiqueta/ícono/visible son editables — nombre de sistema y
  # navegación se muestran de solo lectura (cambiarlos desconectaría
  # catálogos ya anidados adentro).
  def handle_event("abrir_editar_carpeta", %{"nombre" => nombre}, socket) do
    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        {:noreply, put_flash(socket, :error, "Esa carpeta ya no existe.")}

      header ->
        {:noreply,
         socket
         |> assign(:carpeta_editar, %{header: header, contexto: contexto_editar_desde_header(header)})
         |> assign(:carpeta_editar_error, nil)}
    end
  end

  def handle_event("cerrar_editar_carpeta", _params, socket) do
    {:noreply, socket |> assign(:carpeta_editar, nil) |> assign(:carpeta_editar_error, nil)}
  end

  def handle_event("validar_editar_carpeta", %{"contexto" => contexto}, socket) do
    contexto =
      contexto
      |> Map.put("icono", normalizar_icono_carpeta(contexto["icono"]))
      |> Map.put("visible", contexto["visible"] == "true")

    {:noreply, update(socket, :carpeta_editar, &Map.put(&1, :contexto, contexto))}
  end

  def handle_event("elegir_icono_editar_carpeta", %{"icono" => icono}, socket) do
    {:noreply,
     update(socket, :carpeta_editar, fn editar ->
       Map.update!(editar, :contexto, &Map.put(&1, "icono", icono))
     end)}
  end

  def handle_event("guardar_editar_carpeta", %{"contexto" => contexto}, socket) do
    %{header: header} = socket.assigns.carpeta_editar

    case validar_etiqueta_carpeta(contexto["etiqueta"]) do
      :ok ->
        attrs = %{
          "schema_context_label" => String.trim(contexto["etiqueta"]),
          "schema_context_icono" => nil_si_vacio_carpeta(normalizar_icono_carpeta(contexto["icono"])),
          "schema_visible" => contexto["visible"] == "true"
        }

        case MetaSchemaContext.actualizar_header(header, attrs) do
          {:ok, header_actualizado} ->
            Phoenix.PubSub.broadcast(MetadataApp.PubSub, @topic, {:bc_actualizado, header_actualizado})

            {:noreply,
             socket
             |> assign(:carpeta_editar, nil)
             |> assign(:carpeta_editar_error, nil)
             |> put_flash(:info, "Carpeta '#{header_actualizado.schema_context_label}' actualizada.")
             |> cargar_headers()}

          {:error, changeset} ->
            {:noreply,
             socket
             |> update(:carpeta_editar, &Map.put(&1, :contexto, contexto))
             |> assign(:carpeta_editar_error, resumen_errores_carpeta(changeset))}
        end

      {:error, motivo} ->
        {:noreply,
         socket
         |> update(:carpeta_editar, &Map.put(&1, :contexto, contexto))
         |> assign(:carpeta_editar_error, motivo)}
    end
  end

  # "Nueva carpeta"/"Editar carpeta" ya se resuelven solos, arriba, sin
  # depender de este PubSub — sigue transmitiéndose igual por si algo más
  # llega a escucharlo más adelante.
  def handle_info({:bc_creado, _header}, socket) do
    {:noreply, cargar_headers(socket)}
  end

  def handle_info({:bc_actualizado, _header}, socket) do
    {:noreply, cargar_headers(socket)}
  end

  # Pagina por CARPETA RAÍZ, no por fila plana — construir_arbol/1 siempre
  # agrupa el nivel superior en carpetas (hasta un catálogo suelto en la
  # raíz, ej. "/refacciones", se envuelve en una implícita con su propio
  # label — ver el comentario de segmentos_con_carpeta/1 en
  # MetaSchemaContext), así que el árbol completo YA arranca siendo una
  # lista de puras carpetas: "1-30 de N" es "N carpetas madre", no "N
  # filas en toda la base". Antes se paginaba la lista plana ANTES de
  # armar el árbol — eso hacía que una carpeta pudiera aparecer
  # "incompleta" en una página, con el resto de sus hijos recién en la
  # siguiente. Acá se arma el árbol completo primero (en memoria, sin
  # costo de DB extra) y se pagina la lista de raíces resultante, así
  # cada carpeta que aparece en una página siempre trae TODO su
  # subárbol completo, sin importar cuántos niveles tenga.
  # Busca, dentro del árbol de ESTA página, la lista de hijos que
  # corresponde a un `data-contenedor-id` (evento "mover_a" del hook
  # ListaOrdenable) — "" es la raíz (@arbol tal cual), cualquier otro
  # valor es la CLAVE (clave_de_carpeta/2) de una carpeta en algún nivel.
  # Recursivo: la carpeta puede estar a cualquier profundidad, no solo raíz.
  # El "id" de una carpeta SIN Header propio (implícita) es nil, así que
  # el contenedor_id que llega del cliente para ESA carpeta en realidad es
  # la clave sintética "ruta:..." armada por clave_de_carpeta/2 (mismo
  # criterio en los dos lados, ver arbol_editable/1) — hay que reconstruir
  # la misma ruta acumulada acá para poder encontrarla.
  #
  # Devuelve `{hijos, ruta_hijos}`: además de la lista, la ruta acumulada
  # DESDE la raíz hasta este contenedor — es la que hace falta para poder
  # calcular, a su vez, la clave de cada hijo que sea carpeta (ver
  # handle_event("mover_a", ...) arriba).
  defp hijos_de(nodos, ""), do: {nodos, ""}
  defp hijos_de(nodos, contenedor_id), do: buscar_hijos(nodos, "", contenedor_id)

  defp buscar_hijos(nodos, ruta_padre, contenedor_id) do
    Enum.find_value(nodos, fn
      %{tipo: :carpeta, hijos: hijos} = nodo ->
        ruta_nodo = ruta_con(ruta_padre, nodo.segmento)

        if clave_de_carpeta(nodo, ruta_padre) == contenedor_id do
          {hijos, ruta_nodo}
        else
          buscar_hijos(hijos, ruta_nodo, contenedor_id)
        end

      _pagina ->
        nil
    end)
  end

  defp cargar_headers(socket) do
    busqueda = socket.assigns.busqueda
    todos = MetaSchemaContext.listar_headers() |> Enum.map(&MetaSchemaContext.item_de_header/1)
    {carpetas, hojas} = Enum.split_with(todos, & &1.es_carpeta)

    # La búsqueda de texto solo decide qué HOJAS (catálogos/páginas)
    # sobreviven -- las carpetas SIEMPRE se pasan TODAS a construir_arbol/1.
    # Si no, una carpeta real que no matchea por texto pero es ancestro de
    # algo que sí matchea (ej. buscar "material" bajo CROAC/MASTERDATA/
    # PRODUCTOS) quedaba afuera de la lista de entrada -- construir_arbol/1
    # nunca se enteraba de su ícono/etiqueta real y la reconstruía como
    # carpeta "implícita" (ícono genérico "folder", bug real reportado).
    # Lo que la búsqueda SÍ recorta son las ramas que terminan vacías
    # después de armar el árbol completo (podar_carpetas_vacias/2) -- salvo
    # que la carpeta misma haya matcheado por nombre, en cuyo caso se deja
    # ver vacía (mismo criterio que antes para buscar una carpeta por nombre).
    hojas_filtradas = Enum.filter(hojas, &coincide_busqueda?(&1, busqueda))
    ids_carpetas_que_matchean = carpetas |> Enum.filter(&coincide_busqueda?(&1, busqueda)) |> MapSet.new(& &1.id)

    arbol_completo =
      (carpetas ++ hojas_filtradas)
      |> MetaSchemaContext.construir_arbol()
      |> then(fn arbol -> if busqueda == "", do: arbol, else: podar_carpetas_vacias(arbol, ids_carpetas_que_matchean) end)

    total_items = length(arbol_completo)
    total_paginas = max(ceil(total_items / @por_pagina), 1)
    pagina = socket.assigns.pagina |> max(1) |> min(total_paginas)
    offset = (pagina - 1) * @por_pagina

    raices_pagina = Enum.slice(arbol_completo, offset, @por_pagina)

    # puede_desplegar sigue calculándose solo sobre lo que esta página
    # realmente va a mostrar (nunca sobre @total_items) — mismo espíritu
    # que antes, adaptado a que ahora "lo que se muestra" es el subárbol
    # completo de cada carpeta raíz de esta página, no un slice plano de
    # tamaño fijo.
    arbol = Enum.map(raices_pagina, &anotar_nodo/1)

    socket
    |> assign(:arbol, arbol)
    |> assign(:pagina, pagina)
    |> assign(:total_paginas, total_paginas)
    |> assign(:total_items, total_items)
    |> assign(:inicio, if(total_items == 0, do: 0, else: offset + 1))
    |> assign(:fin, min(offset + @por_pagina, total_items))
  end

  # Recorre el árbol de abajo hacia arriba: una carpeta sin hijos después
  # de podar sus propios hijos se elimina, salvo que su `id` esté en
  # `ids_que_matchean` (matcheó por nombre, se deja ver vacía a propósito).
  defp podar_carpetas_vacias(nodos, ids_que_matchean) do
    nodos
    |> Enum.map(fn
      %{tipo: :carpeta} = nodo -> %{nodo | hijos: podar_carpetas_vacias(nodo.hijos, ids_que_matchean)}
      pagina -> pagina
    end)
    |> Enum.reject(fn
      %{tipo: :carpeta, hijos: [], id: id} -> id not in ids_que_matchean
      _ -> false
    end)
  end

  # Camina el subárbol de una carpeta raíz de esta página, anotando cada
  # nodo :pagina con puede_desplegar — las carpetas en sí nunca se anotan
  # (no tienen autómata propio), solo se recorren.
  defp anotar_nodo(%{tipo: :carpeta, hijos: hijos} = nodo) do
    %{nodo | hijos: Enum.map(hijos, &anotar_nodo/1)}
  end

  defp anotar_nodo(%{tipo: :pagina} = nodo) do
    adjuntar_puede_desplegar(nodo)
  end

  # Catálogo Maestro-Detalle: un detalle nunca se publica por separado
  # (comparte el ciclo del maestro, mismo criterio que ya rige sus
  # estados/transiciones/contrato) — acá directamente NO se le calcula
  # puede_desplegar?/1 real, se marca :no_aplica para que el checkbox del
  # wizard no se pinte para un detalle (ver filas_arbol/1). Estas dos
  # funciones reciben nodos :pagina (ver anotar_nodo/2 arriba), que
  # conservan todas las llaves del item plano original de
  # MetaSchemaContext.item_de_header/1 (es_carpeta: false siempre acá, por
  # eso la primera cláusula de cada una nunca matchea en este punto — se
  # deja igual para que ninguna de las dos reviente si alguna vez se les
  # pasa por error un nodo :carpeta).
  defp adjuntar_puede_desplegar(%{es_carpeta: true} = item), do: item

  defp adjuntar_puede_desplegar(%{schema_encabezado_id: id} = item) when not is_nil(id),
    do: Map.put(item, :puede_desplegar, :no_aplica)

  defp adjuntar_puede_desplegar(item),
    do: Map.put(item, :puede_desplegar, MetaEstadosAdmin.puede_desplegar?(item.id))

  # Resultado del Task disparado por confirmar_publicar/3 (start_async/3,
  # ver ahí el motivo). {:ok, {:ok, _}} y {:ok, {:error, _}} son las dos
  # ramas normales de publicar_paquete/2 (éxito / error controlado);
  # {:exit, _} es un crash genuino DENTRO del Task (ej. una excepción no
  # capturada) — sin esta cláusula, ESE caso dejaría el modal colgado en
  # "Procesando…" para siempre.
  def handle_async(:publicar_paquete, {:ok, {:ok, _salida}}, socket) do
    seleccionados = socket.assigns.wizard_publicar.seleccionados

    {:noreply,
     socket
     |> assign(:wizard_publicar, nil)
     |> assign(:seleccionados, MapSet.new())
     |> put_flash(
       :info,
       "Publicado — #{Enum.join(seleccionados, ", ")} va(n) camino a producción. Seguí el progreso con \"gh run watch\" o \"gh run list\"."
     )
     |> cargar_headers()}
  end

  def handle_async(:publicar_paquete, {:ok, {:error, mensaje}}, socket) do
    {:noreply, update(socket, :wizard_publicar, &Map.merge(&1, %{error: mensaje, procesando?: false}))}
  end

  def handle_async(:publicar_paquete, {:exit, razon}, socket) do
    {:noreply,
     update(socket, :wizard_publicar, &Map.merge(&1, %{error: "Error inesperado: #{inspect(razon)}", procesando?: false}))}
  end

  def handle_async(:despublicar_catalogo, {:ok, {:ok, _salida}}, socket) do
    tabla = socket.assigns.accion_eliminar.tabla

    {:noreply,
     socket
     |> assign(:accion_eliminar, nil)
     |> put_flash(
       :info,
       "Despublicado — el borrado de #{tabla} va camino a producción. Seguí el progreso con \"gh run watch\" o \"gh run list\"."
     )}
  end

  def handle_async(:despublicar_catalogo, {:ok, {:error, mensaje}}, socket) do
    {:noreply, update(socket, :accion_eliminar, &Map.merge(&1, %{error: mensaje, procesando?: false}))}
  end

  def handle_async(:despublicar_catalogo, {:exit, razon}, socket) do
    {:noreply,
     update(socket, :accion_eliminar, &Map.merge(&1, %{error: "Error inesperado: #{inspect(razon)}", procesando?: false}))}
  end

  # Espejo de MetadataApp.MetaPublicador (armar_bundle/1's rutas_de/1): con
  # el .ex/meta/motor/reglas ya borrados por Eliminar, lo único que queda
  # en disco para este catálogo es la migración de DROP -- el bundle se
  # arma solo con eso, sin código de empaquetado nuevo (mismo camino que
  # "mix motor.despublicar", ver lib/mix/tasks/motor.despublicar.ex).
  defp despublicar_catalogo(tabla) do
    with {:ok, bundle_path} <- MetaPublicador.armar_bundle([tabla]),
         {:ok, _tags} <- MetaPublicador.persistir_bundle([tabla], bundle_path),
         {:ok, salida} <- MetaPublicador.disparar_deploy([tabla], bundle_path) do
      {:ok, salida}
    end
  end

  # Orquesta el paquete completo desde la UI, sin pasar por ningún
  # Mix.Task (a diferencia de "mix motor.publicar", que sí puede) — esto
  # corre dentro de la app ya viva bajo supervisión, así que llama
  # MetaSchemaContext.exportar_header/1 directo en vez de "mix meta.export".
  defp publicar_paquete(seleccionados, catalogos) do
    with :ok <- regenerar_paquete(catalogos),
         :ok <- exportar_paquete(catalogos),
         {:ok, bundle_path} <- MetaPublicador.armar_bundle(catalogos),
         {:ok, _tags} <- MetaPublicador.persistir_bundle(seleccionados, bundle_path),
         {:ok, salida} <- MetaPublicador.disparar_deploy(seleccionados, bundle_path) do
      {:ok, salida}
    end
  end

  # Equivalente de "mix gen.catalogos" para el paquete calculado — self-heal
  # de cada schema .ex contra la metadata actual antes de empaquetar nada
  # (mismo motivo que motor.publicar.ex: un .ex generado antes de que el
  # catálogo quedara enlazado a un maestro, o antes de un campo nuevo,
  # queda desactualizado en disco si nadie vuelve a correr esto). Una
  # carpeta (schema_context_type: 2, ahora seleccionable para publicar,
  # ver filas_arbol/1) no tiene campos propios ni tabla física — sin este
  # salto, CatalogoGenerador.generar/1 le pega "No hay metadata en
  # meta_schema_detail" y el reduce_while aborta TODO el paquete, aunque
  # el resto de lo seleccionado esté perfecto.
  defp regenerar_paquete(catalogos) do
    Enum.reduce_while(catalogos, :ok, fn nombre, :ok ->
      if es_carpeta?(nombre) do
        {:cont, :ok}
      else
        case CatalogoGenerador.generar(nombre) do
          {:ok, _} -> {:cont, :ok}
          {:error, motivo} -> {:halt, {:error, "#{nombre}: #{motivo}"}}
        end
      end
    end)
  end

  defp es_carpeta?(nombre) do
    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      %{schema_context_type: 2} -> true
      _ -> false
    end
  end

  defp exportar_paquete(catalogos) do
    Enum.each(catalogos, fn nombre ->
      case MetaSchemaContext.obtener_header_por_nombre(nombre) do
        nil ->
          :ok

        header ->
          MetaSchemaContext.exportar_header(header)
          MetaEstadosAdmin.exportar_header(header)
      end
    end)
  end

  defp coincide_busqueda?(_item, ""), do: true

  defp coincide_busqueda?(item, busqueda) do
    objetivo = normalizar_busqueda(item.label) <> " " <> normalizar_busqueda(item.id)
    String.contains?(objetivo, normalizar_busqueda(busqueda))
  end

  defp normalizar_busqueda(texto) do
    texto
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  defp formulario_carpeta_vacio do
    %{
      "etiqueta" => "Catálogo de ",
      "carpeta_padre" => "",
      "nav_final" => "",
      "icono" => "",
      "visible" => true
    }
  end

  defp formulario_consulta_vacio do
    %{"etiqueta" => "", "carpeta_padre" => "", "nav_final" => "", "catalogo_base" => ""}
  end

  # "consulta_" en vez de "pty_carpeta_" — no es un catálogo de negocio
  # (nunca tiene tabla física propia), así que no lleva el prefijo pty_
  # que .gitignore excluye a propósito: una Consulta SÍ debe quedar
  # versionada en git como cualquier otra metadata.
  defp nombre_desde_nav_consulta(nav) do
    sufijo =
      nav
      |> String.trim_leading("/")
      |> String.split("/", trim: true)
      |> Enum.map(&normalizar_identificador_carpeta/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("_")

    if sufijo == "", do: "", else: String.slice("consulta_#{sufijo}", 0, 50)
  end

  # Aplica, en orden, cada unión ya resuelta en @tablas_relacionadas —
  # nunca vuelve a correr detectar_union/2 acá (eso ya pasó, en vivo,
  # mientras se armaba el modal); esto solo persiste EXACTAMENTE lo que
  # el admin vio en el panel "Tablas relacionadas".
  defp agregar_tablas_relacionadas(consulta, tablas) do
    Enum.reduce_while(tablas, {:ok, consulta}, fn tabla, {:ok, consulta_acc} ->
      resultado =
        MetaConsultas.agregar_tabla_manual(
          consulta_acc,
          tabla["catalogo"],
          tabla["campo_en_nuevo"],
          tabla["catalogo_destino"],
          tabla["campo_en_destino"]
        )

      case resultado do
        {:ok, _consulta} -> {:cont, resultado}
        {:error, _motivo} -> {:halt, resultado}
      end
    end)
  end

  defp contexto_editar_desde_header(header) do
    %{
      "etiqueta" => header.schema_context_label,
      "icono" => header.schema_context_icono || "",
      "visible" => header.schema_visible
    }
  end

  defp validar_etiqueta_carpeta(valor) do
    if valor && String.trim(valor) != "" do
      :ok
    else
      {:error, "La etiqueta no puede quedar vacía."}
    end
  end

  # No basta con las restricciones del navegador (pattern/maxlength) — un
  # cliente HTTP directo a este LiveView se las salta. schema_context_name
  # termina siendo un identificador real de Postgres (nombre de tabla que
  # nunca se genera para una carpeta, pero igual queda en meta_schema_header
  # y tiene que respetar el mismo formato que el resto), así que se valida
  # acá también.
  @identificador_carpeta ~r/^[a-z][a-z0-9_]{0,49}$/
  @nav_carpeta ~r/^\/[a-z0-9\-\/]{0,49}$/

  defp validar_formulario_carpeta(contexto) do
    with :ok <- validar_regex_carpeta(contexto["nombre"], @identificador_carpeta, "Nombre de sistema"),
         :ok <- validar_regex_carpeta(contexto["nav"], @nav_carpeta, "Navegación"),
         :ok <- validar_completado_carpeta(contexto["etiqueta"], "Catálogo de", "Etiqueta") do
      validar_nav_libre_carpeta(contexto["nav"])
    end
  end

  defp validar_regex_carpeta(valor, regex, etiqueta) do
    if valor && Regex.match?(regex, valor) do
      :ok
    else
      {:error, "#{etiqueta} inválido: '#{valor}'. Debe cumplir el formato requerido (ver la ayuda del campo)."}
    end
  end

  # Mismo chequeo que en BcMotorLive (Editar encabezado) y BcNuevoCompletoLive
  # (crear catálogo) — sin esto, una carpeta nueva podía terminar apuntando a
  # la misma ruta que un catálogo/carpeta ya existente y "taparlo" en
  # construir_arbol/1 (un nodo por ruta: el segundo pisa al primero).
  defp validar_nav_libre_carpeta(nav) do
    case MetaSchemaContext.obtener_header_por_nav(nav) do
      nil -> :ok
      _otro -> {:error, "Esa ruta de navegación ya la usa otro catálogo o carpeta — elegí otra."}
    end
  end

  # No basta con dejar el valor por default (ej. solo "Catálogo de " sin
  # completar) — tiene que haber algo real después del prefijo.
  defp validar_completado_carpeta(valor, prefijo, etiqueta) do
    resto =
      (valor || "")
      |> String.trim()
      |> String.trim_leading(prefijo)
      |> String.trim()

    if resto == "" do
      {:error, "#{etiqueta} no puede quedarse solo con el valor por default — completa el resto."}
    else
      :ok
    end
  end

  # El "Nombre de sistema" de una carpeta no se pide en el form — se arma
  # solo a partir de los segmentos de la Navegación, que es la única
  # información propia de una carpeta.
  defp nombre_desde_nav_carpeta(nav) do
    sufijo =
      nav
      |> String.trim_leading("/")
      |> String.split("/", trim: true)
      |> Enum.map(&normalizar_identificador_carpeta/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("_")

    if sufijo == "", do: "", else: String.slice("pty_carpeta_#{sufijo}", 0, 50)
  end

  defp normalizar_identificador_carpeta(valor) do
    (valor || "")
    |> String.downcase()
    |> quitar_acentos_carpeta()
    |> String.replace(~r/[^a-z0-9_]/, "")
    |> String.replace(~r/^[^a-z]+/, "")
    |> String.slice(0, 50)
  end

  defp quitar_acentos_carpeta(valor) do
    valor
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  # Nombre del ícono de Material Symbols (fonts.google.com/icons) — la UI de
  # Google los muestra en "Title Case" (ej. "Inventory 2") pero el nombre
  # real del glyph es snake_case ("inventory_2"), así que se normaliza para
  # no depender de que el usuario lo pegue ya en el formato exacto. Devuelve
  # "" (no nil) para que el campo se redibuje igual que nav_final; el
  # guardado convierte "" a nil (sin ícono = cae al genérico de siempre).
  defp normalizar_icono_carpeta(valor) do
    (valor || "")
    |> String.trim()
    |> String.downcase()
    |> quitar_acentos_carpeta()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 50)
  end

  defp nil_si_vacio_carpeta(""), do: nil
  defp nil_si_vacio_carpeta(valor), do: valor

  # Solo el segmento final del nav (lo que escribe el usuario en "Nombre en
  # el menú") — minúsculas, sin acentos/espacios, guiones sí permitidos
  # (a diferencia de normalizar_identificador_carpeta/1, que es para nombres pty_*).
  defp normalizar_slug_carpeta(valor) do
    (valor || "")
    |> String.downcase()
    |> quitar_acentos_carpeta()
    |> String.replace(~r/[^a-z0-9\-]/, "")
    |> String.slice(0, 50)
  end

  # Compone el nav final: carpeta_padre (elegida del selector, puede venir
  # vacía = raíz) + el segmento propio. Así ya no hay que escribir la ruta
  # completa a mano ni arriesgarse a un typo que no calce con ninguna
  # carpeta existente.
  defp componer_nav_carpeta(carpeta_padre, nav_final) do
    segmento = normalizar_slug_carpeta(nav_final)

    cond do
      segmento == "" -> ""
      carpeta_padre in [nil, ""] -> "/" <> segmento
      true -> String.slice("/" <> carpeta_padre <> "/" <> segmento, 0, 50)
    end
  end

  defp resumen_errores_carpeta(changeset), do: changeset |> MetadataApp.MetaErrores.traducir() |> inspect()

  def render(assigns) do
    ~H"""
    <div class="w-full p-4 sm:p-6 lg:p-8">
      <div class="flex items-center justify-between mb-4 flex-wrap gap-3">
        <div class="flex items-center gap-2">
          <h1 class="text-2xl font-bold">BC List</h1>
        </div>
        <div class="flex items-center gap-3 flex-wrap">
          <div class="flex items-center gap-2">
            <span class="text-xs font-medium text-gray-500 bg-gray-100 rounded-full px-3 py-1">
              {@inicio}-{@fin} de {@total_items}
            </span>
            <div class="flex items-center gap-1 bg-gray-50 border border-gray-200 rounded-lg p-0.5">
              <button
                type="button"
                phx-click="pagina_anterior"
                disabled={@pagina <= 1}
                aria-label="Página anterior"
                class="w-7 h-7 flex items-center justify-center rounded-md text-gray-600 hover:bg-white hover:shadow-sm disabled:opacity-30 disabled:cursor-not-allowed disabled:hover:bg-transparent disabled:hover:shadow-none transition"
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
                class="w-7 h-7 flex items-center justify-center rounded-md text-gray-600 hover:bg-white hover:shadow-sm disabled:opacity-30 disabled:cursor-not-allowed disabled:hover:bg-transparent disabled:hover:shadow-none transition"
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                  <polyline points="9 18 15 12 9 6" />
                </svg>
              </button>
            </div>
          </div>
          <div class="flex gap-2 flex-wrap">
            <button

              type="button"
              id="btn-nuevo-contexto"
              phx-click="abrir_form_carpeta"
              class="pc-btn-secundario bg-linear-to-b from-white to-gray-100 hover:to-gray-200 border border-gray-100 text-gray-800 shadow-sm font-semibold text-xs px-4 py-1.5 rounded-full transition-colors"
            >
              + Carpeta
            </button>
            <.link navigate={~p"/sysadmin/bc-list/nuevo-completo"}
              class="pc-btn-secundario bg-linear-to-b from-white to-gray-100 hover:to-gray-200 border border-gray-100 text-gray-800 shadow-sm font-semibold text-xs px-4 py-1.5 rounded-full transition-colors">
              + Catálogo
            </.link>
            <button
              type="button"
              phx-click="abrir_form_consulta"
              title="Consulta Ecto: reporte de solo lectura sobre uno o más catálogos, sin estados ni tabla propia"
              class="pc-btn-secundario bg-linear-to-b from-white to-gray-100 hover:to-gray-200 border border-gray-100 text-gray-800 shadow-sm font-semibold text-xs px-4 py-1.5 rounded-full transition-colors"
            >
              + Ecto
            </button>
            <button
              type="button"
              phx-click="abrir_editar_orden"
              title="Arrastrar las carpetas raíz para cambiar el orden en que aparecen acá y en el menú"
              class="pc-btn-secundario bg-linear-to-b from-white to-gray-100 hover:to-gray-200 border border-gray-100 text-gray-800 shadow-sm font-semibold text-xs px-4 py-1.5 rounded-full transition-colors"
            >
              Vista
            </button>

          </div>
        </div>
      </div>

      <.panel_editar_orden :if={@editando_orden} arbol={@arbol} carpeta_editando_orden={@carpeta_editando_orden} />

      <div :if={!@editando_orden}>
        <div class="mb-4 flex items-center gap-3">
          <input
            type="text"
            value={@busqueda}
            phx-keyup="buscar"
            phx-debounce="200"
            placeholder="Buscar por nombre o etiqueta..."
            class="pc-input-busqueda flex-1 border border-gray-200 rounded-lg px-4 py-2 text-sm text-gray-900"
          />
          <button
            :if={MapSet.size(@seleccionados) > 0}
            type="button"
            phx-click="abrir_wizard_publicar"
            class="flex-shrink-0 bg-purple-600 hover:bg-purple-700 text-white font-bold px-4 py-2 rounded text-sm whitespace-nowrap"
          >
            Publicar paquete ({MapSet.size(@seleccionados)})
          </button>
        </div>

        <div class="overflow-x-auto rounded-xl border border-gray-200">
          <table class="min-w-full divide-y divide-gray-100 text-sm">
            <thead>
              <tr class="border-b-2 border-gray-200">
                <th class="px-4 py-3 w-8"></th>
                <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Nombre de sistema</th>
                <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Etiqueta</th>
                <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Navegación</th>
                <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Estado</th>
                <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide">Acciones</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <.filas_arbol nodos={@arbol} carpetas_expandidas={@carpetas_expandidas} seleccionados={@seleccionados} />
              <%= if @arbol == [] do %>
                <tr>
                  <td class="px-4 py-6 text-center text-gray-400" colspan="6">
                    {if @busqueda == "", do: "Todavía no hay contextos creados", else: "Sin resultados para \"#{@busqueda}\""}
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

    </div>

    <.modal_eliminar accion={@accion_eliminar} />
    <.modal_publicar wizard={@wizard_publicar} />
    <.modal_carpeta form={@carpeta_form} error={@carpeta_error} carpetas={@carpetas_disponibles} />
    <.modal_editar_carpeta editar={@carpeta_editar} error={@carpeta_editar_error} />
    <.modal_consulta
      form={@consulta_form}
      error={@consulta_error}
      carpetas={@carpetas_disponibles}
      catalogos_base={@catalogos_base_disponibles}
      tablas_relacionadas={@tablas_relacionadas}
      selector_abierto={@selector_tabla_relacionada_abierto}
      catalogos_relacionables={@catalogos_relacionables_disponibles}
    />
    <.modal_union_manual union_manual={@union_manual} />
    """
  end

  # "Editar vista": arrastrar carpetas Y archivos para cambiar su orden, a
  # cualquier profundidad — no solo las carpetas raíz. Cada nivel del
  # árbol (la raíz de esta página, y adentro de cada carpeta) es su
  # propio contenedor ListaOrdenable/Sortable.js, con un `data-grupo`
  # ÚNICO por contenedor — a propósito, para que solo se pueda reordenar
  # DENTRO de un mismo nivel, nunca arrastrar sin querer un ítem de una
  # carpeta a otra (eso le cambiaría la ruta de navegación de golpe, sin
  # ninguna confirmación — ver ListaOrdenable en assets/js/app.js).
  #
  # Una carpeta sin `id` real (Header detrás) — implícita, inferida solo
  # de la ruta de lo que tiene adentro — también se puede arrastrar: su
  # orden se guarda por ruta (ver clave_de_carpeta/2 y
  # MetaSchemaContext.reordenar_hermanos/1), no por `schema_context_name`.
  attr :arbol, :list, required: true
  attr :carpeta_editando_orden, :string, default: nil

  defp panel_editar_orden(assigns) do
    carpeta =
      assigns.carpeta_editando_orden &&
        Enum.find(assigns.arbol, &(&1.tipo == :carpeta and clave_de_carpeta(&1, "") == assigns.carpeta_editando_orden))

    assigns =
      assigns
      |> assign(:carpeta, carpeta)
      |> assign(:nodos, if(carpeta, do: carpeta.hijos, else: assigns.arbol))
      |> assign(:ruta_base, if(carpeta, do: carpeta.segmento, else: ""))
      |> assign(:contenedor_base, if(carpeta, do: clave_de_carpeta(carpeta, ""), else: ""))

    ~H"""
    <div class="mb-4 rounded-xl border border-purple-200 bg-purple-50/40 overflow-hidden">
      <div class="flex items-center justify-between px-4 py-2.5 bg-purple-50 border-b border-purple-200">
        <div>
          <h2 class="text-sm font-bold text-purple-900">
            Editar vista<span :if={@carpeta}> — {@carpeta.nombre}</span>
          </h2>
          <p class="text-xs text-purple-600">
            Arrastrá para cambiar el orden — carpetas y archivos, a cualquier nivel. Se guarda solo al soltar, y se refleja acá y en el menú.
          </p>
        </div>
        <button type="button" phx-click="cerrar_editar_orden" class="px-3.5 py-1.5 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700 transition-colors">
          Listo
        </button>
      </div>
      <div class="p-3">
        <.arbol_editable :if={@nodos != []} nodos={@nodos} contenedor_id={@contenedor_base} ruta_padre={@ruta_base} />
        <p :if={@nodos == []} class="px-4 py-6 text-center text-gray-400 text-sm">No hay nada acá para reordenar.</p>
      </div>
    </div>
    """
  end

  # `contenedor_id` de una carpeta SIN Header propio (implícita, ver
  # arriba) no puede ser su `id` (nil) — se arma una clave sintética a
  # partir de la ruta acumulada desde la raíz ("ruta:ecc/ventas"), con un
  # prefijo que nunca puede chocar contra un `schema_context_name` real.
  # Esta misma clave (id real, o "ruta:...") es la que se usa como
  # `data-id` de CADA ítem arrastrable — carpeta implícita incluida — así
  # que también sirve para identificar/persistir su propio orden entre
  # hermanas (ver MetaSchemaContext.reordenar_hermanos/1). Para un nodo
  # :pagina, que siempre tiene `id`, la primera cláusula ya alcanza.
  defp clave_de_carpeta(%{id: id}, _ruta_padre) when not is_nil(id), do: id
  defp clave_de_carpeta(%{segmento: segmento}, ruta_padre), do: "ruta:" <> ruta_con(ruta_padre, segmento)

  defp ruta_con("", segmento), do: segmento
  defp ruta_con(ruta_padre, segmento), do: ruta_padre <> "/" <> segmento

  attr :nodos, :list, required: true
  attr :contenedor_id, :string, default: ""
  attr :ruta_padre, :string, default: ""

  defp arbol_editable(assigns) do
    grupo = "orden-" <> (if assigns.contenedor_id == "", do: "raiz", else: assigns.contenedor_id)
    assigns = assign(assigns, :grupo, grupo)

    ~H"""
    <div id={"orden-lista-" <> @grupo} phx-hook="ListaOrdenable" data-contenedor-id={@contenedor_id} data-grupo={@grupo} class="space-y-1.5">
      <div :for={nodo <- @nodos} id={"orden-nodo-" <> clave_de_carpeta(nodo, @ruta_padre)} data-id={clave_de_carpeta(nodo, @ruta_padre)}>
        <div class="flex items-center gap-2 bg-white border border-gray-200 rounded-lg px-3 py-2 text-sm">
          <svg class="jal-manija text-gray-300 hover:text-gray-500 cursor-grab flex-shrink-0" width="14" height="14" viewBox="0 0 24 24" fill="currentColor" title="Arrastrar para reordenar">
            <circle cx="8" cy="6" r="1.6" /><circle cx="16" cy="6" r="1.6" /><circle cx="8" cy="12" r="1.6" /><circle cx="16" cy="12" r="1.6" /><circle cx="16" cy="18" r="1.6" /><circle cx="8" cy="18" r="1.6" />
          </svg>
          <span class="material-symbols-outlined text-gray-400" style="font-size: 18px">
            {if nodo.tipo == :carpeta, do: "folder", else: "description"}
          </span>
          <span class="font-semibold text-gray-800 flex-1">{if nodo.tipo == :carpeta, do: nodo.nombre, else: nodo.label}</span>
          <span
            :if={!nodo.id}
            class="text-[10px] text-gray-400 italic whitespace-nowrap"
            title="Carpeta automática (sin '+ Nueva carpeta' propia) — no tiene un registro propio, pero su orden y el de su contenido se guardan igual."
          >
            carpeta automática
          </span>
        </div>
        <div :if={nodo.tipo == :carpeta and nodo.hijos != []} class="pl-6 mt-1.5">
          <.arbol_editable nodos={nodo.hijos} contenedor_id={clave_de_carpeta(nodo, @ruta_padre)} ruta_padre={ruta_con(@ruta_padre, nodo.segmento)} />
        </div>
      </div>
    </div>
    """
  end

  # "Nueva carpeta" como modal interno — mismo patrón visual que
  # modal_estado/modal_transicion en BcMotorLive (fixed inset-0 + tarjeta
  # centrada), ya no una ventana emergente del navegador aparte.
  attr :form, :map, default: nil
  attr :error, :string, default: nil
  attr :carpetas, :list, default: []

  defp modal_carpeta(%{form: nil} = assigns), do: ~H""

  defp modal_carpeta(%{form: form} = assigns) do
    assigns = assign(assigns, :nav_preview, componer_nav_carpeta(form["carpeta_padre"], form["nav_final"]))
    assigns = assign(assigns, :iconos_sugeridos, @iconos_sugeridos)

    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-lg w-full max-h-[90vh] overflow-y-auto overflow-x-hidden">
        <div class="flex items-center gap-1.5 bg-[#fafafa] border-b border-gray-200 px-4 py-2.5 rounded-t-xl">
          <span class="material-symbols-outlined text-gray-400" style="font-size: 18px">folder</span>
          <span class="text-sm font-semibold text-gray-900">Nueva carpeta</span>
        </div>

        <%= if @error do %>
          <div class="px-4 py-1.5 text-xs font-medium border-b border-gray-200 bg-red-50 text-red-700">
            {@error}
          </div>
        <% end %>

        <form phx-submit="guardar_carpeta" phx-change="validar_carpeta" class="p-4 space-y-3 text-xs">
          <fieldset class="border border-gray-200 rounded-lg">
            <legend class="px-1.5 ml-2 font-bold uppercase tracking-wide text-[11px] text-gray-500">Contexto</legend>
            <div class="grid grid-cols-1 sm:grid-cols-[110px_1fr] gap-y-1.5 gap-x-2 p-2.5 items-start">
              <label class="font-medium text-gray-900 pt-1">Etiqueta:</label>
              <input type="text" name="contexto[etiqueta]" value={@form["etiqueta"]} required maxlength="100"
                class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500 transition-colors" placeholder="Catálogo de carros" />

              <label class="font-medium text-gray-900 pt-1">Navegación:</label>
              <div class="min-w-0">
                <div class="flex items-center gap-1 flex-wrap">
                  <select name="contexto[carpeta_padre]"
                    title="Elige una carpeta que ya existe para anidar ahí adentro, o deja 'Sin carpeta' para que quede en la raíz del menú."
                    class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 min-w-0 max-w-full focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500 transition-colors">
                    <option value="" selected={@form["carpeta_padre"] in [nil, ""]}>— Sin carpeta (raíz) —</option>
                    <%= for carpeta <- @carpetas do %>
                      <option value={carpeta.ruta} selected={@form["carpeta_padre"] == carpeta.ruta}>{carpeta.etiqueta}</option>
                    <% end %>
                  </select>
                  <span class="text-gray-400">/</span>
                  <input type="text" name="contexto[nav_final]" value={@form["nav_final"]} required maxlength="50"
                    title="Minúsculas, sin acentos ni espacios. Guiones sí permitidos."
                    class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 flex-1 min-w-[8rem] focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500 transition-colors" placeholder="carros" />
                </div>
                <div class="mt-1 bg-purple-50 border border-purple-200 text-purple-700 rounded-lg px-1.5 py-0.5 flex flex-wrap items-center gap-1 max-w-full">
                  <span class="text-purple-400">Vista previa:</span>
                  <span class="font-mono break-all">{@nav_preview}</span>
                </div>
              </div>

              <label class="font-medium text-gray-900 pt-1">Ícono:</label>
              <div>
                <div class="flex items-center gap-4">
                  <input type="hidden" name="contexto[icono]" value={@form["icono"]} />
                  <button
                    type="button"
                    phx-click={JS.toggle(to: "#selector-iconos-carpeta")}
                    class="w-6 h-6 flex items-center justify-center border border-gray-300 rounded-lg bg-gray-50 hover:bg-gray-100 text-gray-700 transition-colors"
                    title="Elegir ícono"
                  >
                    <%= if @form["icono"] not in [nil, ""] do %>
                      <span class="material-symbols-outlined" style="font-size: 16px">{@form["icono"]}</span>
                    <% else %>
                      <span class="material-symbols-outlined text-gray-400" style="font-size: 16px">apps</span>
                    <% end %>
                  </button>

                  <label class="flex items-center gap-1.5 font-medium text-gray-900 cursor-pointer select-none">
                    <input type="hidden" name="contexto[visible]" value="false" />
                    <input type="checkbox" name="contexto[visible]" value="true" checked={@form["visible"] == true} class="accent-purple-600" />
                    Es visible
                  </label>
                </div>

                <div id="selector-iconos-carpeta" class="hidden mt-1 border border-gray-200 rounded-lg bg-white shadow-lg p-1.5">
                  <div class="grid grid-cols-10 gap-0.5 max-h-40 overflow-y-auto">
                    <%= for icono <- @iconos_sugeridos do %>
                      <button
                        type="button"
                        title={icono}
                        phx-click={JS.push("elegir_icono_carpeta", value: %{icono: icono}) |> JS.hide(to: "#selector-iconos-carpeta")}
                        class={[
                          "w-6 h-6 flex items-center justify-center rounded-lg text-gray-700 hover:bg-purple-50 hover:text-purple-700 transition-colors",
                          @form["icono"] == icono && "bg-purple-100 text-purple-700"
                        ]}
                      >
                        <span class="material-symbols-outlined" style="font-size: 16px">{icono}</span>
                      </button>
                    <% end %>
                  </div>
                </div>

                <p class="mt-0.5 text-[11px] text-gray-500">Opcional — se ve en el menú colapsado.</p>
              </div>
            </div>
          </fieldset>

          <div class="flex justify-end gap-2 border-t border-gray-200 pt-3">
            <button type="button" phx-click="cerrar_form_carpeta" class="px-3.5 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50 transition-colors">
              Cancelar
            </button>
            <button type="submit" class="px-3.5 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 transition-colors">
              Guardar
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # "Nueva consulta" (BC tipo 3) — mismo patrón que modal_carpeta, con un
  # selector de catálogo base en vez de ícono/visible (una Consulta
  # siempre nace visible, no tiene ícono propio todavía).
  defp modal_consulta(%{form: nil} = assigns), do: ~H""

  defp modal_consulta(%{form: form} = assigns) do
    assigns = assign(assigns, :nav_preview, componer_nav_carpeta(form["carpeta_padre"], form["nav_final"]))

    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-lg w-full max-h-[90vh] overflow-y-auto overflow-x-hidden">
        <div class="flex items-center gap-1.5 bg-[#fafafa] border-b border-gray-200 px-4 py-2.5 rounded-t-xl">
          <span class="material-symbols-outlined text-gray-400" style="font-size: 18px">function</span>
          <span class="text-sm font-semibold text-gray-900">Nueva consulta (Función Ecto)</span>
        </div>

        <p class="px-4 pt-2 text-[11px] text-gray-500">
          Reporte de solo lectura sobre un catálogo — sin estados, sin transiciones, sin tabla propia. Los campos a mostrar se eligen después, desde el editor de la consulta.
        </p>

        <%= if @error do %>
          <div class="px-4 py-1.5 text-xs font-medium border-b border-gray-200 bg-red-50 text-red-700 mt-2">
            {@error}
          </div>
        <% end %>

        <form phx-submit="guardar_consulta" phx-change="validar_consulta" class="p-4 space-y-3 text-xs">
          <fieldset class="border border-gray-200 rounded-lg">
            <legend class="px-1.5 ml-2 font-bold uppercase tracking-wide text-[11px] text-gray-500">Contexto</legend>
            <div class="grid grid-cols-1 sm:grid-cols-[110px_1fr] gap-y-1.5 gap-x-2 p-2.5 items-start">
              <label class="font-medium text-gray-900 pt-1">Etiqueta:</label>
              <input type="text" name="contexto[etiqueta]" value={@form["etiqueta"]} required maxlength="100"
                class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500 transition-colors" placeholder="Ventas por producto" />

              <label class="font-medium text-gray-900 pt-1">Navegación:</label>
              <div class="min-w-0">
                <div class="flex items-center gap-1 flex-wrap">
                  <select name="contexto[carpeta_padre]"
                    class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 min-w-0 max-w-full focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500 transition-colors">
                    <option value="" selected={@form["carpeta_padre"] in [nil, ""]}>— Sin carpeta (raíz) —</option>
                    <%= for carpeta <- @carpetas do %>
                      <option value={carpeta.ruta} selected={@form["carpeta_padre"] == carpeta.ruta}>{carpeta.etiqueta}</option>
                    <% end %>
                  </select>
                  <span class="text-gray-400">/</span>
                  <input type="text" name="contexto[nav_final]" value={@form["nav_final"]} required maxlength="50"
                    class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 flex-1 min-w-[8rem] focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500 transition-colors" placeholder="ventas-por-producto" />
                </div>
                <div class="mt-1 bg-purple-50 border border-purple-200 text-purple-700 rounded-lg px-1.5 py-0.5 flex flex-wrap items-center gap-1 max-w-full">
                  <span class="text-purple-400">Vista previa:</span>
                  <span class="font-mono break-all">{@nav_preview}</span>
                </div>
              </div>

              <label class="font-medium text-gray-900 pt-1">Catálogo base:</label>
              <select name="contexto[catalogo_base]" required
                class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 w-full min-w-0 max-w-full focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500 transition-colors">
                <option value="">— Elegir —</option>
                <%= for c <- @catalogos_base do %>
                  <option value={c.nombre} selected={@form["catalogo_base"] == c.nombre}>{c.etiqueta}</option>
                <% end %>
              </select>
            </div>
          </fieldset>

          <fieldset :if={@form["catalogo_base"] not in [nil, ""]} class="border border-gray-200 rounded-lg">
            <legend class="px-1.5 ml-2 font-bold uppercase tracking-wide text-[11px] text-gray-500">Tablas relacionadas (opcional)</legend>
            <div class="p-2.5">
              <p :if={@tablas_relacionadas == []} class="text-gray-400 mb-2">
                Solo <strong>{@form["catalogo_base"]}</strong> por ahora — agregá más tablas si el reporte necesita combinar datos de varias.
              </p>
              <ul :if={@tablas_relacionadas != []} class="space-y-1 mb-2">
                <li :for={{t, indice} <- Enum.with_index(@tablas_relacionadas)} class="flex items-center justify-between gap-2 bg-gray-50 border border-gray-200 rounded-lg px-2 py-1.5">
                  <span class="min-w-0">
                    <strong class="text-gray-900">{t["catalogo"]}</strong>
                    <%= if t["sin_union"] do %>
                      <span class="text-red-600"> — sin unión definida</span>
                    <% else %>
                      <span class="text-gray-500 font-mono break-all"> — {t["catalogo"]}.{t["campo_en_nuevo"]} = {t["catalogo_destino"]}.{t["campo_en_destino"]}</span>
                    <% end %>
                    <p :if={t["maestro_detalle"]} class="text-amber-700">
                      Detalle de <strong>{t["maestro_detalle"]}</strong> — puede traer varias filas por cada {t["maestro_detalle"]}.
                    </p>
                  </span>
                  <div class="flex items-center gap-2 flex-shrink-0">
                    <button type="button" phx-click="abrir_union_manual" phx-value-indice={indice} class="text-purple-700 hover:text-purple-900 font-semibold">
                      {if t["sin_union"], do: "Definir", else: "Cambiar"}
                    </button>
                    <button :if={indice == length(@tablas_relacionadas) - 1} type="button" phx-click="quitar_ultima_tabla_relacionada" class="text-red-600 hover:text-red-800 font-semibold">
                      Quitar
                    </button>
                  </div>
                </li>
              </ul>

              <div class="relative inline-block">
                <button type="button" phx-click="abrir_selector_tabla_relacionada" class="text-purple-700 hover:text-purple-900 font-semibold">
                  + Agregar tabla relacionada
                </button>
                <%= if @selector_abierto do %>
                  <div class="fixed inset-0 z-40" phx-click="cerrar_selector_tabla_relacionada"></div>
                  <div class="absolute left-0 top-full mt-1 w-56 max-h-48 overflow-y-auto bg-white border border-gray-200 rounded-lg shadow-lg z-50 py-1">
                    <button
                      :for={c <- @catalogos_relacionables}
                      type="button"
                      phx-click="agregar_tabla_relacionada"
                      phx-value-catalogo={c.nombre}
                      class="w-full text-left px-3 py-1.5 text-gray-700 hover:bg-purple-50 hover:text-purple-700"
                    >
                      {c.etiqueta}
                    </button>
                    <p :if={@catalogos_relacionables == []} class="px-3 py-2 text-gray-400">No hay más catálogos disponibles.</p>
                  </div>
                <% end %>
              </div>
            </div>
          </fieldset>

          <div class="flex justify-end gap-2 border-t border-gray-200 pt-3">
            <button type="button" phx-click="cerrar_form_consulta" class="px-3.5 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50 transition-colors">
              Cancelar
            </button>
            <button type="submit" class="px-3.5 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 transition-colors">
              Crear consulta
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # Editor manual de unión — modal apilado sobre "Nueva consulta" (mismo
  # patrón que "abrir_form_campo" en BcNuevoCompletoLive: un sub-form
  # aparte, nunca un <form> anidado dentro del form grande de arriba, que
  # sería HTML inválido). Aparece automático cuando "Agregar tabla
  # relacionada" no encuentra ninguna "Relación" ya configurada entre esa
  # tabla y las que ya están en la consulta, o cuando el admin quiere
  # cambiar la unión que sí se autodetectó.
  defp modal_union_manual(%{union_manual: nil} = assigns), do: ~H""

  defp modal_union_manual(%{union_manual: um} = assigns) do
    assigns = assign(assigns, :um, um)

    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-[60] p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-md w-full max-h-[90vh] overflow-y-auto">
        <div class="flex items-center gap-1.5 bg-[#fafafa] border-b border-gray-200 px-4 py-2.5 rounded-t-xl">
          <span class="material-symbols-outlined text-gray-400" style="font-size: 18px">link</span>
          <span class="text-sm font-semibold text-gray-900">Unión con "{@um.catalogo}"</span>
        </div>

        <form phx-submit="guardar_union_manual" class="p-4 space-y-3 text-xs">
          <p class="text-gray-500">
            No hay ninguna "Relación" configurada entre <strong>{@um.catalogo}</strong> y las tablas que ya están en la
            consulta — elegí a mano qué campo de cada lado conecta.
          </p>

          <p :if={@um.maestro_detalle} class="text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-2 py-1.5">
            <strong>{@um.catalogo}</strong> es detalle de <strong>{@um.maestro_detalle}</strong> — puede traer varias
            filas por cada {@um.maestro_detalle}.
          </p>

          <div>
            <label class="block font-medium text-gray-900 mb-1">Campo en "{@um.catalogo}":</label>
            <select name="campo_en_nuevo" phx-change="cambiar_campo_union_manual" required
              class="w-full border border-gray-300 rounded-lg text-gray-900 px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500">
              <%= for campo <- @um.campos_nuevo do %>
                <option value={campo} selected={campo == @um.campo_en_nuevo_elegido}>{campo}</option>
              <% end %>
            </select>
            <p :if={@um.maestro_detalle && @um.campo_en_nuevo_elegido == "id"} class="mt-1 text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-2 py-1.5">
              "id" casi seguro no es correcto acá — {@um.catalogo} es detalle de {@um.maestro_detalle}, la clave para
              unirlo es "encabezado_id".
            </p>
          </div>

          <div>
            <label class="block font-medium text-gray-900 mb-1">Se une con:</label>
            <select name="destino" required class="w-full border border-gray-300 rounded-lg text-gray-900 px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500">
              <%= for {catalogo, campo} <- @um.opciones_destino do %>
                <option value={"#{catalogo}:#{campo}"}>{catalogo}.{campo}</option>
              <% end %>
            </select>
          </div>

          <div class="flex justify-end gap-2 border-t border-gray-200 pt-3">
            <button type="button" phx-click="cerrar_union_manual" class="px-3.5 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50 transition-colors">
              Cancelar
            </button>
            <button type="submit" class="px-3.5 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 transition-colors">
              Guardar unión
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # "Editar carpeta" como modal interno — mismo patrón que modal_carpeta.
  # Solo etiqueta/ícono/visible son editables; nombre de sistema y
  # navegación se muestran de solo lectura (cambiarlos desconectaría
  # catálogos ya anidados adentro — para eso hay que borrar y crear de
  # nuevo en la ruta correcta).
  attr :editar, :map, default: nil
  attr :error, :string, default: nil

  defp modal_editar_carpeta(%{editar: nil} = assigns), do: ~H""

  defp modal_editar_carpeta(%{editar: %{header: header, contexto: contexto}} = assigns) do
    assigns = assign(assigns, :header, header)
    assigns = assign(assigns, :contexto, contexto)
    assigns = assign(assigns, :iconos_sugeridos, @iconos_sugeridos)

    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-lg w-full max-h-[90vh] overflow-y-auto overflow-x-hidden">
        <div class="flex items-center gap-1.5 bg-[#fafafa] border-b border-gray-200 px-4 py-2.5 rounded-t-xl">
          <span class="material-symbols-outlined text-gray-400" style="font-size: 18px">folder</span>
          <span class="text-sm font-semibold text-gray-900">Editar carpeta</span>
        </div>

        <%= if @error do %>
          <div class="px-4 py-1.5 text-xs font-medium border-b border-gray-200 bg-red-50 text-red-700">
            {@error}
          </div>
        <% end %>

        <form phx-submit="guardar_editar_carpeta" phx-change="validar_editar_carpeta" class="p-4 space-y-3 text-xs">
          <fieldset class="border border-gray-200 rounded-lg">
            <legend class="px-1.5 ml-2 font-bold uppercase tracking-wide text-[11px] text-gray-500">Contexto</legend>
            <div class="grid grid-cols-1 sm:grid-cols-[110px_1fr] gap-y-1.5 gap-x-2 p-2.5 items-start">
              <label class="font-medium text-gray-900 pt-1">Nombre de sistema:</label>
              <span class="font-mono text-gray-500 pt-1 break-all">{@header.schema_context_name}</span>

              <label class="font-medium text-gray-900 pt-1">Navegación:</label>
              <div class="min-w-0">
                <span class="font-mono text-gray-500 break-all">{@header.schema_context_nav}</span>
                <p class="mt-0.5 text-[11px] text-gray-500">
                  La ruta no se edita aquí — cambiarla desconectaría los catálogos que ya
                  están anidados adentro. Si hace falta moverla, bórrala y créala de
                  nuevo en la ruta correcta.
                </p>
              </div>

              <label class="font-medium text-gray-900 pt-1">Etiqueta:</label>
              <input type="text" name="contexto[etiqueta]" value={@contexto["etiqueta"]} required maxlength="100"
                class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500 transition-colors" placeholder="Catálogo de carros" />

              <label class="font-medium text-gray-900 pt-1">Ícono:</label>
              <div>
                <div class="flex items-center gap-4">
                  <input type="hidden" name="contexto[icono]" value={@contexto["icono"]} />
                  <button
                    type="button"
                    phx-click={JS.toggle(to: "#selector-iconos-editar-carpeta")}
                    class="w-6 h-6 flex items-center justify-center border border-gray-300 rounded-lg bg-gray-50 hover:bg-gray-100 text-gray-700 transition-colors"
                    title="Elegir ícono"
                  >
                    <%= if @contexto["icono"] not in [nil, ""] do %>
                      <span class="material-symbols-outlined" style="font-size: 16px">{@contexto["icono"]}</span>
                    <% else %>
                      <span class="material-symbols-outlined text-gray-400" style="font-size: 16px">apps</span>
                    <% end %>
                  </button>

                  <label class="flex items-center gap-1.5 font-medium text-gray-900 cursor-pointer select-none">
                    <input type="hidden" name="contexto[visible]" value="false" />
                    <input type="checkbox" name="contexto[visible]" value="true" checked={@contexto["visible"] == true} class="accent-purple-600" />
                    Es visible
                  </label>
                </div>

                <div id="selector-iconos-editar-carpeta" class="hidden mt-1 border border-gray-200 rounded-lg bg-white shadow-lg p-1.5">
                  <div class="grid grid-cols-10 gap-0.5 max-h-40 overflow-y-auto">
                    <%= for icono <- @iconos_sugeridos do %>
                      <button
                        type="button"
                        title={icono}
                        phx-click={JS.push("elegir_icono_editar_carpeta", value: %{icono: icono}) |> JS.hide(to: "#selector-iconos-editar-carpeta")}
                        class={[
                          "w-6 h-6 flex items-center justify-center rounded-lg text-gray-700 hover:bg-purple-50 hover:text-purple-700 transition-colors",
                          @contexto["icono"] == icono && "bg-purple-100 text-purple-700"
                        ]}
                      >
                        <span class="material-symbols-outlined" style="font-size: 16px">{icono}</span>
                      </button>
                    <% end %>
                  </div>
                </div>

                <p class="mt-0.5 text-[11px] text-gray-500">Opcional — se ve en el menú colapsado.</p>
              </div>
            </div>
          </fieldset>

          <div class="flex justify-end gap-2 border-t border-gray-200 pt-3">
            <button type="button" phx-click="cerrar_editar_carpeta" class="px-3.5 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50 transition-colors">
              Cancelar
            </button>
            <button type="submit" class="px-3.5 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 transition-colors">
              Guardar
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # Modal de confirmación de borrado — dos variantes según lo que haya
  # contestado CatalogoGenerador.impacto/1 en "pedir_eliminar":
  # :confirmar (sin dependientes, puede seguir) o :bloqueado (hay otro
  # catálogo referenciando a este, no tiene sentido ofrecer continuar).
  attr :accion, :map, default: nil

  defp modal_eliminar(%{accion: nil} = assigns), do: ~H""

  defp modal_eliminar(%{accion: %{tipo: :confirmar}} = assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-md w-full p-6">
        <h2 class="text-lg font-bold text-gray-900 mb-2">Eliminar catálogo</h2>
        <p class="text-sm text-gray-700 mb-4">
          Se eliminará el catálogo <strong>{@accion.label}</strong> ({@accion.tabla}) —
          <strong>{@accion.filas}</strong> fila(s). Este proceso no es reversible.
        </p>

        <label class="block text-sm text-gray-700 mb-1.5">
          Escribe <strong>"{@accion.tabla}"</strong> para confirmar:
        </label>
        <input
          type="text"
          value={@accion.confirmar_texto}
          phx-keyup="escribir_confirmacion_eliminar"
          autocomplete="off"
          placeholder={@accion.tabla}
          class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm text-gray-900 mb-6 focus:outline-none focus:ring-2 focus:ring-red-500/40 focus:border-red-500"
        />

        <div class="flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancelar_eliminar"
            class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50"
          >
            Cancelar
          </button>
          <button
            type="button"
            phx-click="confirmar_eliminar"
            disabled={@accion.confirmar_texto != @accion.tabla}
            class="px-4 py-2 rounded bg-red-600 text-white text-sm font-semibold hover:bg-red-700 disabled:opacity-40 disabled:cursor-not-allowed disabled:hover:bg-red-600"
          >
            Eliminar
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Paso siguiente tras borrar un catálogo pty_*/demo100_* local (ver
  # siguiente_paso_tras_eliminar/2) -- ofrece llevar ese borrado a
  # producción ya mismo, sin salir de BC List. "Omitir" no deshace nada:
  # el catálogo ya está borrado acá, solo pospone la sincronización con
  # producción para hacerla después con "mix motor.despublicar" a mano.
  defp modal_eliminar(%{accion: %{tipo: :despublicar}} = assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-md w-full p-6">
        <h2 class="text-lg font-bold text-gray-900 mb-2">Despublicar de producción</h2>

        <%= if @accion.procesando? do %>
          <div class="flex flex-col items-center justify-center py-10 gap-3">
            <svg class="animate-spin h-8 w-8 text-purple-600" viewBox="0 0 24 24" fill="none">
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
              <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
            </svg>
            <p class="text-sm font-semibold text-gray-700">Procesando…</p>
            <p class="text-xs text-gray-500 text-center max-w-xs">
              No cierres esta ventana — se está armando el paquete y disparando el deploy a producción.
            </p>
          </div>
        <% else %>
          <p class="text-sm text-gray-700 mb-4">
            <strong>{@accion.label}</strong> ({@accion.tabla}) ya se borró acá, pero es un catálogo
            <span class="font-mono">pty_*</span> — nunca pasa por git, así que <code>commit</code>/<code>push</code>
            no alcanza. Producción todavía lo tiene.
          </p>

          <div :if={@accion.error} class="mb-4 rounded-lg border border-red-200 bg-red-50 text-red-700 text-sm px-3 py-2">
            {@accion.error}
          </div>

          <div class="flex justify-end gap-3">
            <button
              type="button"
              phx-click="cancelar_eliminar"
              class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50"
            >
              Omitir
            </button>
            <button
              type="button"
              phx-click="confirmar_despublicar"
              class="px-4 py-2 rounded bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700"
            >
              Despublicar de producción
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp modal_eliminar(%{accion: %{tipo: :confirmar_carpeta}} = assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-md w-full p-6">
        <h2 class="text-lg font-bold text-gray-900 mb-2">Eliminar carpeta</h2>
        <p class="text-sm text-gray-700 mb-6">
          Se eliminará la carpeta <strong>"{@accion.label}"</strong> del menú. ¿Desea continuar?
        </p>
        <div class="flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancelar_eliminar"
            class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50"
          >
            Cancelar
          </button>
          <button
            type="button"
            phx-click="confirmar_eliminar_carpeta"
            class="px-4 py-2 rounded bg-red-600 text-white text-sm font-semibold hover:bg-red-700"
          >
            Eliminar
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp modal_eliminar(%{accion: %{tipo: :confirmar_consulta}} = assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-md w-full p-6">
        <h2 class="text-lg font-bold text-gray-900 mb-2">Eliminar consulta</h2>
        <p class="text-sm text-gray-700 mb-6">
          Se eliminará la consulta <strong>"{@accion.label}"</strong>. Este proceso no es reversible.
        </p>
        <div class="flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancelar_eliminar"
            class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50"
          >
            Cancelar
          </button>
          <button
            type="button"
            phx-click="confirmar_eliminar_consulta"
            class="px-4 py-2 rounded bg-red-600 text-white text-sm font-semibold hover:bg-red-700"
          >
            Eliminar
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp modal_eliminar(%{accion: %{tipo: :bloqueado}} = assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-md w-full p-6">
        <h2 class="text-lg font-bold text-gray-900 mb-2">No se puede eliminar</h2>
        <p class="text-sm text-gray-700 mb-6">
          Hay otro catálogo con un campo "referencia" apuntando a este ({Enum.join(@accion.dependientes, ", ")}).
          Hay que borrar o desenganchar esos primero.
        </p>
        <div class="flex justify-end">
          <button
            type="button"
            phx-click="cancelar_eliminar"
            class="px-4 py-2 rounded bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700"
          >
            Aceptar
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Wizard de publicación: preview de solo lectura del paquete completo
  # (calculado por MetaPublicador.validar/1 — detalles + cierre de
  # referencias, ya en orden topológico) antes de tocar producción. El
  # orden nunca lo elige quien publica — mismo criterio que ya usa
  # cualquier gestor de paquetes real (ver docs/roadmap.md): un humano
  # ordenando dependencias a mano es exactamente el error que causó el bug
  # real del primer deploy (2026-07-23, catálogo referenciado que no
  # existía todavía en producción).
  attr :wizard, :map, default: nil

  defp modal_publicar(%{wizard: nil} = assigns), do: ~H""

  defp modal_publicar(assigns) do
    assigns = assign(assigns, :automaticos, assigns.wizard.catalogos -- assigns.wizard.seleccionados)

    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-lg w-full max-h-[90vh] overflow-y-auto p-6">
        <h2 class="text-lg font-bold text-gray-900 mb-1">Publicar paquete</h2>

        <%= if @wizard.procesando? do %>
          <div class="flex flex-col items-center justify-center py-10 gap-3">
            <svg class="animate-spin h-8 w-8 text-purple-600" viewBox="0 0 24 24" fill="none">
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
              <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
            </svg>
            <p class="text-sm font-semibold text-gray-700">Procesando…</p>
            <p class="text-xs text-gray-500 text-center max-w-xs">
              No cierres esta ventana — se está armando el paquete y disparando el deploy a producción.
            </p>
          </div>
        <% else %>
          <p class="text-sm text-gray-600 mb-4">
            Se va a armar un paquete con {length(@wizard.catalogos)} catálogo(s) y disparar el deploy a producción.
          </p>

          <div :if={@wizard.error} class="mb-4 rounded-lg border border-red-200 bg-red-50 text-red-700 text-sm px-3 py-2">
            {@wizard.error}
          </div>

          <div class="mb-4">
            <h3 class="text-xs font-bold uppercase tracking-wide text-gray-500 mb-1.5">Seleccionados</h3>
            <ul class="text-sm text-gray-800 space-y-0.5">
              <li :for={nombre <- @wizard.seleccionados} class="font-mono">{nombre}</li>
            </ul>
          </div>

          <div :if={@automaticos != []} class="mb-4">
            <h3 class="text-xs font-bold uppercase tracking-wide text-gray-500 mb-1.5">
              Incluidos automáticamente (detalles / referencias)
            </h3>
            <ul class="text-sm text-gray-500 space-y-0.5">
              <li :for={nombre <- @automaticos} class="font-mono">{nombre}</li>
            </ul>
          </div>

          <div :if={@wizard.problemas != []} class="mb-4">
            <h3 class="text-xs font-bold uppercase tracking-wide text-gray-500 mb-1.5">Advertencias</h3>
            <ul class="text-xs text-gray-600 space-y-0.5">
              <li :for={p <- @wizard.problemas}>[{p.severidad}] {p.mensaje}</li>
            </ul>
          </div>

          <p class="text-xs text-gray-500 mb-4">
            Orden de publicación: <span class="font-mono">{Enum.join(@wizard.catalogos, " → ")}</span>
          </p>

          <div class="flex justify-end gap-3 border-t border-gray-200 pt-4">
            <button
              type="button"
              phx-click="cancelar_wizard_publicar"
              class="px-4 py-2 rounded border border-gray-300 text-gray-700 text-sm font-semibold hover:bg-gray-50"
            >
              Cancelar
            </button>
            <button
              type="button"
              phx-click="confirmar_publicar"
              phx-disable-with="Procesando…"
              class="px-4 py-2 rounded bg-purple-600 text-white text-sm font-semibold hover:bg-purple-700 disabled:opacity-60"
            >
              Publicar
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Filas de la tabla agrupadas igual que el menú: una fila de encabezado
  # gris por carpeta, recursivo para soportar carpetas anidadas.
  attr :nodos, :list, required: true
  attr :nivel, :integer, default: 0

  attr :carpetas_expandidas, :any, default: MapSet.new()
  attr :ruta_padre, :string, default: ""
  attr :seleccionados, :any, default: MapSet.new()

  def filas_arbol(assigns) do
    ~H"""
    <%= for nodo <- @nodos do %>
      <%= if nodo.tipo == :carpeta do %>
        <% ruta = if @ruta_padre == "", do: nodo.segmento, else: @ruta_padre <> "/" <> nodo.segmento %>
        <% expandida? = MapSet.member?(@carpetas_expandidas, ruta) %>
        <tr class="bg-gray-50 hover:bg-gray-100 transition-colors">
          <td class="px-4 py-2">
            <%!-- Solo una carpeta EXPLÍCITA (nodo.id != nil, tiene su propio
                 meta_schema_header) es publicable — una implícita (inferida
                 solo del nav de lo que tiene adentro, sin fila propia) no
                 existe como algo que "publicar" pueda empaquetar. A
                 diferencia de un catálogo, acá no hay validar_motor/1 que
                 chequear (una carpeta no tiene autómata propio) — siempre
                 elegible si existe de verdad. --%>
            <input
              :if={nodo.id != nil}
              type="checkbox"
              checked={MapSet.member?(@seleccionados, nodo.id)}
              phx-click="toggle_seleccion"
              phx-value-tabla={nodo.id}
              class="accent-purple-600"
            />
          </td>
          <td
            colspan="5"
            class="px-4 py-2 text-xs select-none"
            style={"padding-left: #{16 + @nivel * 20}px"}
          >
            <div class="flex items-center justify-between gap-2">
              <button
                type="button"
                phx-click="toggle_carpeta"
                phx-value-ruta={ruta}
                class="pc-carpeta-fila flex items-center gap-2 font-normal text-gray-600 uppercase tracking-wide cursor-pointer flex-1 text-left"
              >
                <span class="pc-carpeta-chevron inline-block w-3 text-gray-400">{if expandida?, do: "▾", else: "▸"}</span>
                <span class="w-6 h-6 rounded-md bg-gray-400/30 text-(--pc-texto) flex items-center justify-center flex-shrink-0">
                  <span class="material-symbols-outlined" style="font-size: 15px">
                    {if Map.get(nodo, :icono) not in [nil, ""], do: nodo.icono, else: "folder"}
                  </span>
                </span>
                {nodo.nombre}
              </button>
              <%= if nodo.id || (@nivel == 0 and nodo.hijos != []) do %>
                <div class="flex items-center gap-2 normal-case tracking-normal flex-shrink-0 pc-acciones-chip rounded-lg px-2.5 py-1">
                  <%= if nodo.id do %>
                    <button
                      type="button"
                      id={"btn-editar-carpeta-#{nodo.id}"}
                      phx-click="abrir_editar_carpeta"
                      phx-value-nombre={nodo.id}
                      class="text-blue-600 hover:text-blue-800 text-xs font-semibold"
                    >
                      Editar
                    </button>
                    <%= if nodo.hijos == [] do %>
                      <button
                        type="button"
                        phx-click="pedir_eliminar_carpeta"
                        phx-value-nombre={nodo.id}
                        phx-value-label={nodo.nombre}
                        class="text-red-600 hover:text-red-800 text-xs font-semibold"
                      >
                        Eliminar
                      </button>
                    <% end %>
                  <% end %>
                  <%= if @nivel == 0 and nodo.hijos != [] do %>
                    <button
                      type="button"
                      id={"btn-vista-carpeta-#{clave_de_carpeta(nodo, @ruta_padre)}"}
                      phx-click="abrir_editar_orden_carpeta"
                      phx-value-clave={clave_de_carpeta(nodo, @ruta_padre)}
                      title="Reordenar solo el contenido de esta carpeta madre"
                      class="text-purple-600 hover:text-purple-800 text-xs font-semibold"
                    >
                      Vista
                    </button>
                  <% end %>
                </div>
              <% end %>
            </div>
          </td>
        </tr>
        <%= if expandida? do %>
          <.filas_arbol nodos={nodo.hijos} nivel={@nivel + 1} carpetas_expandidas={@carpetas_expandidas} ruta_padre={ruta} seleccionados={@seleccionados} />
        <% end %>
      <% else %>
        <tr class="hover:bg-gray-50 transition-colors">
          <td class="px-4 py-2.5">
            <input
              :if={nodo.puede_desplegar == true}
              type="checkbox"
              checked={MapSet.member?(@seleccionados, nodo.id)}
              phx-click="toggle_seleccion"
              phx-value-tabla={nodo.id}
              class="accent-purple-600"
            />
          </td>
          <td class="px-4 py-2.5" style={"padding-left: #{16 + @nivel * 20}px"}>
            <div class="flex items-center gap-2">
              <span class="w-6 h-6 rounded-md bg-gray-400/30 text-(--pc-texto) flex items-center justify-center flex-shrink-0">
                <span class="material-symbols-outlined" style="font-size: 15px">
                  <%= cond do %>
                    <% Map.get(nodo, :icono) not in [nil, ""] -> %>{nodo.icono}
                    <% Map.get(nodo, :es_consulta, false) -> %>search
                    <% true -> %>description
                  <% end %>
                </span>
              </span>
              <span class="font-semibold text-gray-800">{nodo.id}</span>
            </div>
          </td>
          <td class="px-4 py-2.5 text-gray-600">
            <span
              :if={Map.get(nodo, :es_consulta, false)}
              class="inline-block mr-1.5 px-1.5 py-0.5 rounded text-[10px] font-semibold uppercase tracking-wide bg-purple-100 text-purple-700"
            >
              Consulta
            </span>
            {nodo.label}
          </td>
          <td class="px-4 py-2.5 text-gray-600 max-w-[260px]">
            <div class="flex items-center gap-1 min-w-0">
              <span class="truncate" title={nodo.nav}>{nodo.nav}</span>
              <button
                type="button"
                id={"copiar-nav-#{nodo.id}"}
                phx-hook="CopiarRuta"
                data-nav={nodo.nav}
                title="Copiar la ruta"
                class="pc-breadcrumb-copiar"
              >
                <svg class="pc-breadcrumb-copiar-icono-copiar" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                  <rect x="9" y="9" width="12" height="12" rx="2" />
                  <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
                </svg>
                <svg class="pc-breadcrumb-copiar-icono-listo" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                  <polyline points="20 6 9 17 4 12" />
                </svg>
              </button>
            </div>
          </td>
          <td class="px-4 py-2.5">
            <span class={[
              "inline-block px-2 py-0.5 rounded-full text-[10px] font-semibold uppercase tracking-wide",
              if(nodo.visible, do: "bg-green-100 text-green-700", else: "bg-gray-100 text-gray-500")
            ]}>
              {if nodo.visible, do: "Visible", else: "Oculto"}
            </span>
          </td>
          <td class="px-4 py-2.5">
            <div class="inline-flex flex-wrap items-center gap-2 pc-acciones-chip rounded-lg px-2.5 py-1">
              <.link
                :if={not Map.get(nodo, :es_consulta, false)}
                navigate={~p"/sysadmin/bc-list/#{nodo.id}/motor"}
                class="text-blue-600 hover:text-blue-800 text-xs font-semibold"
              >
                Editar
              </.link>
              <.link
                :if={Map.get(nodo, :es_consulta, false)}
                navigate={~p"/sysadmin/bc-list/#{nodo.id}/consulta"}
                class="text-blue-600 hover:text-blue-800 text-xs font-semibold"
              >
                Editar
              </.link>
              <button
                :if={Map.get(nodo, :es_consulta, false)}
                type="button"
                phx-click="pedir_eliminar_consulta"
                phx-value-nombre={nodo.id}
                phx-value-label={nodo.label}
                class="text-red-600 hover:text-red-800 text-xs font-semibold"
              >
                Eliminar
              </button>
              <button
                :if={not Map.get(nodo, :es_consulta, false)}
                type="button"
                phx-click="pedir_eliminar"
                phx-value-tabla={nodo.id}
                phx-value-label={nodo.label}
                class="text-red-600 hover:text-red-800 text-xs font-semibold"
              >
                Eliminar
              </button>
            </div>
          </td>
        </tr>
      <% end %>
    <% end %>
    """
  end
end
