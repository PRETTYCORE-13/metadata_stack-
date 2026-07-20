defmodule MetadataAppWeb.Sysadmin.BcListLive do
  use MetadataAppWeb, :live_view_admin

  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerador
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BorradoresMotor
  alias MetadataAppWeb.AdminNav
  alias Phoenix.LiveView.JS

  @topic "bc_contextos"
  @por_pagina 50

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
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"}
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
     |> assign(:carpetas_colapsadas, MapSet.new())
     |> assign(:accion_eliminar, nil)
     |> assign(:carpeta_form, nil)
     |> assign(:carpeta_error, nil)
     |> assign(:carpetas_disponibles, [])
     |> assign(:carpeta_editar, nil)
     |> assign(:carpeta_editar_error, nil)
     |> cargar_borradores()
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
    colapsadas = socket.assigns.carpetas_colapsadas

    colapsadas =
      if MapSet.member?(colapsadas, ruta) do
        MapSet.delete(colapsadas, ruta)
      else
        MapSet.put(colapsadas, ruta)
      end

    {:noreply, assign(socket, :carpetas_colapsadas, colapsadas)}
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

  def handle_event("cancelar_eliminar", _params, socket) do
    {:noreply, assign(socket, :accion_eliminar, nil)}
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
      case CatalogoGenerador.eliminar(tabla, tabla, filas) do
        {:ok, _resultado} ->
          {:noreply,
           socket
           |> assign(:accion_eliminar, nil)
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

  # "Continuar" un borrador solo navega — la carga real pasa en el mount de
  # BcNuevoCompletoLive (ver cargar_estado_inicial/2 ahí). Acá solo hace
  # falta poder borrar uno directamente desde la lista, sin tener que abrir
  # el wizard primero.
  def handle_event("eliminar_borrador", %{"id" => id}, socket) do
    case BorradoresMotor.obtener_borrador(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Ese borrador ya no existe.")}

      borrador ->
        {:ok, _} = BorradoresMotor.eliminar_borrador(borrador)
        Phoenix.PubSub.broadcast(MetadataApp.PubSub, @topic, {:borrador_eliminado, borrador})

        {:noreply,
         socket
         |> put_flash(:info, "Borrador '#{borrador.nombre}' eliminado.")
         |> cargar_borradores()}
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

  # El wizard (BcNuevoCompletoLive) avisa por acá cuando guarda/borra un
  # borrador, así esta lista se refresca sola aunque el cambio haya pasado
  # en otra pestaña.
  def handle_info({:borrador_guardado, _borrador}, socket) do
    {:noreply, cargar_borradores(socket)}
  end

  def handle_info({:borrador_eliminado, _borrador}, socket) do
    {:noreply, cargar_borradores(socket)}
  end

  defp cargar_borradores(socket) do
    assign(socket, :borradores, BorradoresMotor.listar_borradores())
  end

  defp formatear_fecha_borrador(fecha) do
    Calendar.strftime(fecha, "%d/%m/%Y %H:%M")
  end

  # Se pagina la lista PLANA (antes de armar el árbol) — por eso una carpeta
  # puede aparecer "incompleta" en una página y seguir en la siguiente, es el
  # trade-off normal de paginar algo que se agrupa después. Con @por_pagina
  # bastante alto (50) esto casi no se nota en la práctica.
  defp cargar_headers(socket) do
    filtrados =
      MetaSchemaContext.listar_headers()
      |> Enum.map(&MetaSchemaContext.item_de_header/1)
      |> Enum.filter(&coincide_busqueda?(&1, socket.assigns.busqueda))

    total_items = length(filtrados)
    total_paginas = max(ceil(total_items / @por_pagina), 1)
    pagina = socket.assigns.pagina |> max(1) |> min(total_paginas)

    arbol =
      filtrados
      |> Enum.slice((pagina - 1) * @por_pagina, @por_pagina)
      |> MetaSchemaContext.construir_arbol()

    socket
    |> assign(:arbol, arbol)
    |> assign(:pagina, pagina)
    |> assign(:total_paginas, total_paginas)
    |> assign(:total_items, total_items)
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

  defp resumen_errores_carpeta(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> inspect()
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-8">
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">BC List</h1>
        <div class="flex gap-2">
          <button
            type="button"
            id="btn-nuevo-contexto"
            phx-click="abrir_form_carpeta"
            class="bg-white border border-purple-600 text-purple-700 hover:bg-purple-50 font-bold px-6 py-2 rounded"
          >
            + Nueva carpeta
          </button>
          <.link navigate={~p"/sysadmin/bc-list/nuevo-completo"}
            class="bg-purple-600 hover:bg-purple-700 text-white font-bold px-6 py-2 rounded">
            + Nuevo catálogo
          </.link>
        </div>
      </div>

      <.seccion_borradores :if={@borradores != []} borradores={@borradores} />

      <div class="mb-4">
        <input
          type="text"
          value={@busqueda}
          phx-keyup="buscar"
          phx-debounce="200"
          placeholder="Buscar por nombre o etiqueta..."
          class="w-full border border-gray-300 rounded-lg px-4 py-2 text-sm text-gray-900"
        />
      </div>

      <div class="overflow-x-auto rounded-xl border border-gray-200">
        <table class="min-w-full divide-y divide-gray-200 text-sm">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Nombre de sistema</th>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Etiqueta</th>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Navegación</th>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Es visible</th>
              <th class="px-4 py-2 text-left font-semibold text-gray-600">Acciones</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <.filas_arbol nodos={@arbol} carpetas_colapsadas={@carpetas_colapsadas} />
            <%= if @arbol == [] do %>
              <tr>
                <td class="px-4 py-6 text-center text-gray-400" colspan="5">
                  {if @busqueda == "", do: "Todavía no hay contextos creados", else: "Sin resultados para \"#{@busqueda}\""}
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%= if @total_paginas > 1 do %>
        <div class="flex items-center justify-between mt-4 text-sm text-gray-600">
          <span>
            Página {@pagina} de {@total_paginas} ({@total_items} en total)
          </span>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="pagina_anterior"
              disabled={@pagina <= 1}
              class="px-3 py-1.5 rounded border border-gray-300 disabled:opacity-40 disabled:cursor-not-allowed hover:bg-gray-50"
            >
              ← Anterior
            </button>
            <button
              type="button"
              phx-click="pagina_siguiente"
              disabled={@pagina >= @total_paginas}
              class="px-3 py-1.5 rounded border border-gray-300 disabled:opacity-40 disabled:cursor-not-allowed hover:bg-gray-50"
            >
              Siguiente →
            </button>
          </div>
        </div>
      <% end %>
    </div>

    <.modal_eliminar accion={@accion_eliminar} />
    <.modal_carpeta form={@carpeta_form} error={@carpeta_error} carpetas={@carpetas_disponibles} />
    <.modal_editar_carpeta editar={@carpeta_editar} error={@carpeta_editar_error} />
    """
  end

  # Catálogos que alguien empezó a diseñar en el wizard (BcNuevoCompletoLive)
  # y guardó como borrador antes de terminar — "Continuar" navega para allá
  # con ?borrador=<id> (ver cargar_estado_inicial/2 ahí), que recarga todo
  # en memoria tal cual quedó. Solo se muestra si hay al menos uno (ver
  # :if en render/1) para no sumar ruido cuando no hace falta.
  attr :borradores, :list, required: true

  defp seccion_borradores(assigns) do
    ~H"""
    <div class="mb-4 rounded-xl border border-purple-200 overflow-hidden">
      <div class="bg-purple-50 px-4 py-2 border-b border-purple-200">
        <h2 class="text-sm font-bold text-purple-900">Borradores</h2>
        <p class="text-xs text-purple-600">Catálogos que empezaste a diseñar pero todavía no creaste.</p>
      </div>
      <table class="min-w-full divide-y divide-gray-100 text-sm">
        <tbody class="divide-y divide-gray-100">
          <%= for b <- @borradores do %>
            <tr>
              <td class="px-4 py-2 text-gray-800">{b.nombre}</td>
              <td class="px-4 py-2 text-gray-500">Editado {formatear_fecha_borrador(b.updated_at)}</td>
              <td class="px-4 py-2">
                <div class="flex gap-2 justify-end">
                  <.link navigate={~p"/sysadmin/bc-list/nuevo-completo?borrador=#{b.id}"}
                    class="text-blue-600 hover:text-blue-800 text-xs font-semibold">
                    Continuar
                  </.link>
                  <button
                    type="button"
                    phx-click="eliminar_borrador"
                    phx-value-id={b.id}
                    data-confirm={"¿Eliminar el borrador \"#{b.nombre}\"?"}
                    class="text-red-600 hover:text-red-800 text-xs font-semibold"
                  >
                    Eliminar
                  </button>
                </div>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
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
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div class="bg-white rounded-xl shadow-lg max-w-lg w-full max-h-[90vh] overflow-y-auto">
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
            <div class="grid grid-cols-[110px_1fr] gap-y-1.5 gap-x-2 p-2.5 items-start">
              <label class="font-medium text-gray-900 pt-1">Etiqueta:</label>
              <input type="text" name="contexto[etiqueta]" value={@form["etiqueta"]} required maxlength="100"
                class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500 transition-colors" placeholder="Catálogo de carros" />

              <label class="font-medium text-gray-900 pt-1">Navegación:</label>
              <div>
                <div class="flex items-center gap-1">
                  <select name="contexto[carpeta_padre]"
                    title="Elige una carpeta que ya existe para anidar ahí adentro, o deja 'Sin carpeta' para que quede en la raíz del menú."
                    class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500 transition-colors">
                    <option value="" selected={@form["carpeta_padre"] in [nil, ""]}>— Sin carpeta (raíz) —</option>
                    <%= for carpeta <- @carpetas do %>
                      <option value={carpeta.ruta} selected={@form["carpeta_padre"] == carpeta.ruta}>{carpeta.etiqueta}</option>
                    <% end %>
                  </select>
                  <span class="text-gray-400">/</span>
                  <input type="text" name="contexto[nav_final]" value={@form["nav_final"]} required maxlength="50"
                    title="Minúsculas, sin acentos ni espacios. Guiones sí permitidos."
                    class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 flex-1 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500 transition-colors" placeholder="carros" />
                </div>
                <div class="mt-1 bg-purple-50 border border-purple-200 text-purple-700 rounded-lg px-1.5 py-0.5 inline-flex items-center gap-1">
                  <span class="text-purple-400">Vista previa:</span>
                  <span class="font-mono">{@nav_preview}</span>
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
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div class="bg-white rounded-xl shadow-lg max-w-lg w-full max-h-[90vh] overflow-y-auto">
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
            <div class="grid grid-cols-[110px_1fr] gap-y-1.5 gap-x-2 p-2.5 items-start">
              <label class="font-medium text-gray-900 pt-1">Nombre de sistema:</label>
              <span class="font-mono text-gray-500 pt-1">{@header.schema_context_name}</span>

              <label class="font-medium text-gray-900 pt-1">Navegación:</label>
              <div>
                <span class="font-mono text-gray-500">{@header.schema_context_nav}</span>
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
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
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

  defp modal_eliminar(%{accion: %{tipo: :confirmar_carpeta}} = assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
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

  defp modal_eliminar(%{accion: %{tipo: :bloqueado}} = assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
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

  # Filas de la tabla agrupadas igual que el menú: una fila de encabezado
  # gris por carpeta, recursivo para soportar carpetas anidadas.
  attr :nodos, :list, required: true
  attr :nivel, :integer, default: 0

  attr :carpetas_colapsadas, :any, default: MapSet.new()
  attr :ruta_padre, :string, default: ""

  def filas_arbol(assigns) do
    ~H"""
    <%= for nodo <- @nodos do %>
      <%= if nodo.tipo == :carpeta do %>
        <% ruta = if @ruta_padre == "", do: nodo.segmento, else: @ruta_padre <> "/" <> nodo.segmento %>
        <% colapsada? = MapSet.member?(@carpetas_colapsadas, ruta) %>
        <tr class="bg-gray-50 hover:bg-gray-100">
          <td
            colspan="5"
            class="px-4 py-1.5 text-xs select-none"
            style={"padding-left: #{16 + @nivel * 20}px"}
          >
            <div class="flex items-center justify-between gap-2">
              <button
                type="button"
                phx-click="toggle_carpeta"
                phx-value-ruta={ruta}
                class="flex items-center gap-1 font-semibold text-gray-500 uppercase tracking-wide cursor-pointer flex-1 text-left"
              >
                <span class="inline-block w-3">{if colapsada?, do: "▸", else: "▾"}</span>
                📁 {nodo.nombre}
              </button>
              <%= if nodo.id do %>
                <div class="flex gap-2 normal-case tracking-normal flex-shrink-0">
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
                </div>
              <% end %>
            </div>
          </td>
        </tr>
        <%= if !colapsada? do %>
          <.filas_arbol nodos={nodo.hijos} nivel={@nivel + 1} carpetas_colapsadas={@carpetas_colapsadas} ruta_padre={ruta} />
        <% end %>
      <% else %>
        <tr>
          <td class="px-4 py-2 text-gray-800" style={"padding-left: #{16 + @nivel * 20}px"}>{nodo.id}</td>
          <td class="px-4 py-2 text-gray-800">{nodo.label}</td>
          <td class="px-4 py-2 text-gray-800">{nodo.nav}</td>
          <td class="px-4 py-2 text-gray-800">{if nodo.visible, do: "Sí", else: "No"}</td>
          <td class="px-4 py-2">
            <div class="flex gap-2">
              <.link navigate={~p"/sysadmin/bc-list/#{nodo.id}/motor"} class="text-blue-600 hover:text-blue-800 text-xs font-semibold">
                Editar
              </.link>
              <button
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
