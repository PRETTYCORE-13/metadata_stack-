defmodule MetadataAppWeb.Sysadmin.BcNuevoCompletoLive do
  # Wizard de creación completa de un Business Process: Contexto+Campos+
  # Estados+Transiciones+Reglas, todo junto. A diferencia de BcMotorLive
  # (que edita algo que YA existe, cada acción pega a la base al toque),
  # acá NADA toca la base hasta el botón final "Crear Business Process" —
  # todo se acumula en los assigns (mismo principio que ya usa BcNuevoLive
  # para Contexto+Componentes) y se manda de una sola vez a
  # MetaEstadosAdmin.crear_proceso_completo/1 (Fase 1, Ecto.Multi atómico:
  # todo o nada, con la guarda de completitud ya construida — campos +
  # estados + alta/inicial + al menos 1 regla).
  #
  # Reusa el mismo lenguaje visual y los mismos modales que BcMotorLive
  # (agregar campo/estado/transición/regla) — la diferencia es que acá
  # "guardar" en cada modal solo actualiza una lista en memoria, no llama a
  # ninguna función de MetaEstadosAdmin/MetaSchemaContext todavía.
  use MetadataAppWeb, :live_view_admin

  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerador}
  alias MetadataApp.MetaEstadosAdmin
  alias MetadataApp.BorradoresMotor
  alias Phoenix.LiveView.JS

  @topic "bc_contextos"

  @menu [
    %{tipo: :pagina, id: "bc_list", label: "BC List", nav: "/sysadmin/bc-list"}
  ]

  @tipos_campo ~w(string integer decimal boolean date enum referencia)

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

  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_page, "bc_list")
     |> assign(:menu_items, @menu)
     |> assign(:sidebar_open, false)
     |> assign(:carpetas, MetaSchemaContext.listar_carpetas_existentes())
     |> assign(:catalogos_referenciables, MetaSchemaContext.listar_catalogos_referenciables())
     |> assign(:iconos_sugeridos, @iconos_sugeridos)
     |> assign(:mensaje, nil)
     |> assign(:contexto_nav_error, nil)
     |> assign(:campo_form, nil)
     |> assign(:estado_form, nil)
     |> assign(:transicion_form, nil)
     |> assign(:regla_form, nil)
     |> cargar_estado_inicial(params)}
  end

  # Sin "?borrador=<id>": wizard vacío de siempre. Con ese param, se
  # recarga en memoria el JSON completo que había guardado "Guardar
  # borrador" — mismo shape (contexto/campos/estados/transiciones) que ya
  # usan los assigns, así que no hace falta transformar nada al leerlo.
  defp cargar_estado_inicial(socket, %{"borrador" => id}) do
    case BorradoresMotor.obtener_borrador(id) do
      nil ->
        socket
        |> nuevo_formulario()
        |> put_flash(:error, "Ese borrador ya no existe (puede que alguien más lo haya borrado).")

      borrador ->
        contenido = borrador.contenido_json

        socket
        |> assign(:borrador_id, borrador.id)
        |> assign(:contexto, contenido["contexto"] || %{})
        |> assign(:campos, contenido["campos"] || [])
        |> assign(:estados, contenido["estados"] || [])
        |> assign(:transiciones, contenido["transiciones"] || [])
    end
  end

  defp cargar_estado_inicial(socket, _params), do: nuevo_formulario(socket)

  defp nuevo_formulario(socket) do
    socket
    |> assign(:borrador_id, nil)
    |> assign(:contexto, %{
      "nombre" => "",
      "etiqueta" => "Catálogo de ",
      "carpeta_padre" => "",
      "icono" => "",
      "visible" => true
    })
    |> assign(:campos, [])
    |> assign(:estados, [])
    |> assign(:transiciones, [])
  end

  # --- Contexto ------------------------------------------------------------

  # Un solo campo "nombre" hace doble función: es el sufijo del nombre de
  # sistema (pty_<nombre>) Y, convertido a slug con guiones, el segmento
  # final de la Navegación — antes había que escribir el mismo valor dos
  # veces (nombre_p3 y nav_final), redundante en la enorme mayoría de los
  # casos donde ambos terminan siendo la misma palabra. La carpeta padre
  # sigue siendo un select aparte (elegir dónde, no escribir dónde).
  def handle_event("validar_contexto", %{"contexto" => contexto}, socket) do
    contexto =
      contexto
      |> Map.put("visible", contexto["visible"] == "true")
      |> Map.put("nombre", normalizar_identificador(contexto["nombre"]))
      |> Map.put("icono", normalizar_icono(contexto["icono"]))

    nav = componer_nav(contexto["carpeta_padre"], contexto["nombre"])

    error =
      if nav != "" and MetaSchemaContext.obtener_header_por_nav(nav) do
        "Esa ruta ya la usa otro catálogo o carpeta."
      end

    {:noreply,
     socket
     |> assign(:contexto, contexto)
     |> assign(:contexto_nav_error, error)}
  end

  def handle_event("elegir_icono_contexto", %{"icono" => icono}, socket) do
    {:noreply, update(socket, :contexto, &Map.put(&1, "icono", icono))}
  end

  # --- Campos: agregar/quitar (en memoria) ------------------------------------

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
       "opcional" => false,
       "error" => nil
     })}
  end

  def handle_event("cerrar_form_campo", _params, socket) do
    {:noreply, assign(socket, :campo_form, nil)}
  end

  # Solo existe para que el modal reaccione en vivo al elegir "referencia"
  # en Tipo (mostrar/ocultar el selector de Catálogo destino) — el resto de
  # los campos del form no tenían necesidad de reactividad antes de esto.
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

      Enum.any?(socket.assigns.campos, &(&1["nombre"] == nombre)) ->
        {:noreply, update(socket, :campo_form, &Map.put(&1, "error", "Ya hay un campo con ese nombre."))}

      tipo == "referencia" and catalogo == "" ->
        {:noreply, update(socket, :campo_form, &Map.put(&1, "error", "Elegí a qué catálogo apunta la referencia."))}

      true ->
        campo = %{
          "nombre" => nombre,
          "etiqueta" => etiqueta,
          "tipo" => tipo,
          "longitud" => params["longitud"] || "",
          "precision" => params["precision"] || "",
          "escala" => params["escala"] || "",
          "catalogo" => catalogo,
          "opcional" => params["opcional"] == "true"
        }

        {:noreply,
         socket
         |> update(:campos, &(&1 ++ [campo]))
         |> assign(:campo_form, nil)}
    end
  end

  def handle_event("quitar_campo", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)
    {:noreply, update(socket, :campos, &List.delete_at(&1, idx))}
  end

  # --- Estados: agregar/quitar (en memoria) -----------------------------------

  # El botón ya viene disabled en panel_estados/1 mientras no haya Campos
  # (ver motor_stepper/pasos_wizard) — este chequeo es el que de verdad
  # importa, por si alguien manda el evento igual saltándose el disabled.
  def handle_event("abrir_form_estado", _params, socket) do
    if socket.assigns.campos != [] do
      {:noreply,
       assign(socket, :estado_form, %{
         "nombre" => "",
         "orden" => to_string(length(socket.assigns.estados) + 1),
         "es_inicial" => socket.assigns.estados == [],
         "color" => "#7c3aed",
         "icono" => "",
         "error" => nil
       })}
    else
      {:noreply, put_flash(socket, :error, "Agregá al menos un campo antes de agregar estados.")}
    end
  end

  def handle_event("cerrar_form_estado", _params, socket) do
    {:noreply, assign(socket, :estado_form, nil)}
  end

  def handle_event("elegir_icono_estado", %{"icono" => icono}, socket) do
    {:noreply, update(socket, :estado_form, &Map.put(&1, "icono", icono))}
  end

  def handle_event("guardar_estado", params, socket) do
    nombre = String.trim(params["nombre"] || "")

    cond do
      nombre == "" ->
        {:noreply, update(socket, :estado_form, &Map.put(&1, "error", "El nombre no puede quedar vacío."))}

      Enum.any?(socket.assigns.estados, &(&1["nombre"] == nombre)) ->
        {:noreply, update(socket, :estado_form, &Map.put(&1, "error", "Ya hay un estado con ese nombre."))}

      true ->
        es_inicial = params["es_inicial"] == "true"

        estados =
          if es_inicial do
            Enum.map(socket.assigns.estados, &Map.put(&1, "es_inicial", false))
          else
            socket.assigns.estados
          end

        estado = %{
          "nombre" => nombre,
          "orden" => params["orden"],
          "es_inicial" => es_inicial,
          "color" => nil_si_vacio(params["color"]),
          "icono" => nil_si_vacio(normalizar_icono(params["icono"]))
        }

        {:noreply,
         socket
         |> assign(:estados, estados ++ [estado])
         |> assign(:estado_form, nil)}
    end
  end

  def handle_event("quitar_estado", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)
    nombre = Enum.at(socket.assigns.estados, idx)["nombre"]

    # Si algo ya lo referencia como origen/destino, no se deja huérfano —
    # mismo criterio que eliminar_estado/1 en el motor ya guardado.
    referenciado? =
      Enum.any?(socket.assigns.transiciones, &(&1["estado_origen"] == nombre or &1["estado_destino"] == nombre))

    if referenciado? do
      {:noreply, put_flash(socket, :error, "Ese estado ya lo usa una transición — quitá la transición primero.")}
    else
      {:noreply, update(socket, :estados, &List.delete_at(&1, idx))}
    end
  end

  # --- Transiciones: agregar/quitar (en memoria) ------------------------------

  # Mismo criterio que abrir_form_estado/3: el botón ya viene disabled
  # mientras no haya un estado inicial (o transición de alta) definido.
  def handle_event("abrir_form_transicion", _params, socket) do
    if socket.assigns.estados != [] and tiene_alta_o_inicial?(socket.assigns.estados, socket.assigns.transiciones) do
      {:noreply,
       assign(socket, :transicion_form, %{
         "accion" => "",
         "etiqueta" => "",
         "estado_origen" => "",
         "estado_destino" => "",
         "campos_editables" => [],
         "error" => nil
       })}
    else
      {:noreply, put_flash(socket, :error, "Definí un estado inicial antes de agregar transiciones.")}
    end
  end

  def handle_event("cerrar_form_transicion", _params, socket) do
    {:noreply, assign(socket, :transicion_form, nil)}
  end

  def handle_event("guardar_transicion", params, socket) do
    accion = String.trim(params["accion"] || "")
    etiqueta = String.trim(params["etiqueta"] || "")
    destino = params["estado_destino"] || ""
    campos_editables = params |> Map.get("campos_editables", []) |> List.wrap() |> Enum.reject(&(&1 == ""))

    cond do
      accion == "" ->
        {:noreply, update(socket, :transicion_form, &Map.put(&1, "error", "La acción no puede quedar vacía."))}

      destino == "" ->
        {:noreply, update(socket, :transicion_form, &Map.put(&1, "error", "Elegí un estado destino."))}

      true ->
        transicion = %{
          "accion" => accion,
          "etiqueta" => etiqueta,
          "estado_origen" => nil_si_vacio(params["estado_origen"]),
          "estado_destino" => destino,
          "campos_editables" => campos_editables,
          "reglas" => []
        }

        {:noreply,
         socket
         |> update(:transiciones, &(&1 ++ [transicion]))
         |> assign(:transicion_form, nil)}
    end
  end

  def handle_event("quitar_transicion", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)
    {:noreply, update(socket, :transiciones, &List.delete_at(&1, idx))}
  end

  # --- Reglas: agregar/quitar sobre una transición en memoria -----------------

  def handle_event("abrir_form_regla", %{"transicion_idx" => idx}, socket) do
    {:noreply, assign(socket, :regla_form, %{transicion_idx: String.to_integer(idx), regla: nil, error: nil})}
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
        regla = %{
          "tipo" => tipo,
          "regla" => nombre,
          "params" => normalizar_params_regla(nombre, Map.get(params, "params", %{})),
          "orden" => 0,
          "transaccional" => true
        }

        idx = socket.assigns.regla_form.transicion_idx

        transiciones =
          List.update_at(socket.assigns.transiciones, idx, &Map.update!(&1, "reglas", fn r -> r ++ [regla] end))

        {:noreply,
         socket
         |> assign(:transiciones, transiciones)
         |> assign(:regla_form, nil)}

      :error ->
        {:noreply, update(socket, :regla_form, &Map.put(&1, :error, "Elegí una regla de la lista."))}
    end
  end

  def handle_event("quitar_regla", %{"transicion_idx" => tidx, "regla_idx" => ridx}, socket) do
    tidx = String.to_integer(tidx)
    ridx = String.to_integer(ridx)

    transiciones =
      List.update_at(socket.assigns.transiciones, tidx, &Map.update!(&1, "reglas", fn r -> List.delete_at(r, ridx) end))

    {:noreply, assign(socket, :transiciones, transiciones)}
  end

  # Página completa navegada normalmente — "Cancelar" navega de vuelta a la
  # lista sin guardar nada (si quería conservar lo que llevaba armado,
  # tenía que darle a "Guardar borrador" antes).
  def handle_event("cancelar", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/sysadmin/bc-list")}
  end

  # --- Guardar borrador ---------------------------------------------------

  # Reusa el campo "nombre" de Contexto como nombre del borrador — ya es
  # obligatorio conceptualmente para poder crear el BC de verdad, así que no
  # hace falta pedir uno aparte solo para guardar el borrador. La primera vez
  # inserta una fila nueva; de ahí en más (borrador_id ya asignado) actualiza
  # la misma, así "Guardar borrador" repetido no genera duplicados.
  def handle_event("guardar_borrador", _params, socket) do
    %{contexto: contexto, campos: campos, estados: estados, transiciones: transiciones} = socket.assigns
    nombre = String.trim(contexto["nombre"] || "")

    if nombre == "" do
      {:noreply, put_flash(socket, :error, "Ponle un nombre en Contexto antes de guardar el borrador.")}
    else
      contenido = %{"contexto" => contexto, "campos" => campos, "estados" => estados, "transiciones" => transiciones}

      resultado =
        case socket.assigns.borrador_id do
          nil -> BorradoresMotor.crear_borrador(nombre, contenido)
          id -> BorradoresMotor.actualizar_borrador(BorradoresMotor.obtener_borrador(id), nombre, contenido)
        end

      case resultado do
        {:ok, borrador} ->
          Phoenix.PubSub.broadcast(MetadataApp.PubSub, @topic, {:borrador_guardado, borrador})

          {:noreply,
           socket
           |> assign(:borrador_id, borrador.id)
           |> put_flash(:info, "Borrador '#{borrador.nombre}' guardado.")}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, "No se pudo guardar el borrador: #{resumen_errores(changeset)}")}
      end
    end
  end

  # --- Crear: todo o nada -------------------------------------------------------

  def handle_event("crear", _params, socket) do
    contexto = socket.assigns.contexto
    nombre_sistema = nombre_sistema_desde(contexto["nombre"])
    nav = componer_nav(contexto["carpeta_padre"], contexto["nombre"])

    case validar_contexto(nombre_sistema, nav, contexto["etiqueta"]) do
      :ok ->
        attrs = %{
          "header" => %{
            "schema_context_name" => nombre_sistema,
            "schema_context_label" => contexto["etiqueta"],
            "schema_context_nav" => nav,
            "schema_visible" => contexto["visible"] == true,
            "schema_context_type" => 1,
            "schema_context_icono" => nil_si_vacio(contexto["icono"]),
            "detalles" => Enum.map(socket.assigns.campos, &detalle_attrs/1)
          },
          "estados" => socket.assigns.estados,
          "transiciones" => socket.assigns.transiciones
        }

        case MetaEstadosAdmin.crear_proceso_completo(attrs) do
          {:ok, %{header: header}} ->
            CatalogoGenerador.generar(header.schema_context_name)
            Phoenix.PubSub.broadcast(MetadataApp.PubSub, @topic, {:bc_creado, header})
            eliminar_borrador_si_existe(socket.assigns.borrador_id)

            {:noreply, push_navigate(socket, to: ~p"/sysadmin/bc-list/#{header.schema_context_name}/motor")}

          error ->
            {:noreply, assign(socket, :mensaje, {:error, formatear_error_creacion(error)})}
        end

      {:error, motivo} ->
        {:noreply, assign(socket, :mensaje, {:error, motivo})}
    end
  end

  # El borrador ya cumplió su función una vez el BC quedó creado de verdad
  # — se borra (soft-delete) para que no quede colgando en la lista de
  # "Borradores" de BC List como si todavía hiciera falta retomarlo.
  defp eliminar_borrador_si_existe(nil), do: :ok

  defp eliminar_borrador_si_existe(id) do
    case BorradoresMotor.obtener_borrador(id) do
      nil -> :ok
      borrador ->
        {:ok, borrador} = BorradoresMotor.eliminar_borrador(borrador)
        Phoenix.PubSub.broadcast(MetadataApp.PubSub, @topic, {:borrador_eliminado, borrador})
    end
  end

  # campos_requeridos.campos: texto separado por coma -> lista, sin vacíos.
  defp normalizar_params_regla("campos_requeridos", %{"campos" => campos}) do
    lista = campos |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    %{"campos" => lista}
  end

  defp normalizar_params_regla(
         "mutar_relacionados",
         %{"entidad" => entidad, "campo_relacion" => cr, "cambio_campo" => cc, "cambio_valor" => cv}
       ) do
    %{"entidad" => entidad, "campo_relacion" => cr, "cambio" => %{"campo" => cc, "valor" => cv}}
  end

  defp normalizar_params_regla(_regla, params), do: params

  defp formatear_error_creacion({:error, motivo}) when is_binary(motivo), do: motivo
  defp formatear_error_creacion({:error, _paso, %Ecto.Changeset{} = changeset, _cambios}), do: resumen_errores(changeset)
  defp formatear_error_creacion({:error, _paso, motivo, _cambios}) when is_binary(motivo), do: motivo
  defp formatear_error_creacion(_), do: "No se pudo crear el Business Process."

  @identificador ~r/^[a-z][a-z0-9_]{0,49}$/
  @nav ~r/^\/[a-z0-9\-\/]{0,49}$/

  defp validar_contexto(nombre, nav, etiqueta) do
    with :ok <- validar_regex(nombre, @identificador, "Nombre de sistema"),
         :ok <- validar_regex(nav, @nav, "Navegación"),
         :ok <- validar_completado(etiqueta, "Catálogo de", "Etiqueta") do
      validar_nav_libre(nav)
    end
  end

  defp validar_regex(valor, regex, etiqueta) do
    if valor && Regex.match?(regex, valor) do
      :ok
    else
      {:error, "#{etiqueta} inválido: '#{valor}'. Debe cumplir el formato requerido."}
    end
  end

  # Mismo chequeo que el de "Editar encabezado" en BcMotorLive — acá
  # aplicado antes de crear, para que crear un catálogo nuevo no pueda
  # pisar silenciosamente la ruta de uno que ya existe (ver
  # construir_arbol/1: un nav duplicado hace que uno de los dos
  # "desaparezca" del menú, aunque siga vivo en la base).
  defp validar_nav_libre(nav) do
    case MetaSchemaContext.obtener_header_por_nav(nav) do
      nil -> :ok
      _otro -> {:error, "Esa ruta de navegación ya la usa otro catálogo o carpeta — elegí otra."}
    end
  end

  defp validar_completado(valor, prefijo, etiqueta) do
    resto = (valor || "") |> String.trim() |> String.trim_leading(prefijo) |> String.trim()
    if resto == "", do: {:error, "#{etiqueta} no puede quedarse solo con el valor por default."}, else: :ok
  end

  defp nombre_sistema_desde(nombre) do
    n = normalizar_identificador(nombre)
    if n == "", do: "", else: String.slice("pty_#{n}", 0, 50)
  end

  # El segmento de nav se deriva del mismo "nombre" que arma el nombre de
  # sistema — normalizar_identificador ya lo deja en minúsculas/sin
  # acentos/solo [a-z0-9_]; para nav se usan guiones en vez de guion_bajo
  # (convención de URL ya establecida en el resto de la app).
  defp componer_nav(carpeta_padre, nombre) do
    segmento = normalizar_identificador(nombre) |> String.replace("_", "-")

    cond do
      segmento == "" -> ""
      carpeta_padre in [nil, ""] -> "/" <> segmento
      true -> String.slice("/" <> carpeta_padre <> "/" <> segmento, 0, 50)
    end
  end

  defp detalle_attrs(c) do
    propiedades =
      %{"etiqueta" => c["etiqueta"], "tipo" => c["tipo"], "orden" => 1, "visible" => true, "editable" => true, "opcional" => c["opcional"]}
      |> agregar_opciones_tipo_campo(c["tipo"], c)

    %{"schema_context_field" => c["nombre"], "schema_context_properties" => propiedades}
  end

  defp agregar_opciones_tipo_campo(propiedades, "string", c), do: maybe_put_int(propiedades, "longitud", c["longitud"])

  defp agregar_opciones_tipo_campo(propiedades, "decimal", c),
    do: propiedades |> maybe_put_int("precision", c["precision"]) |> maybe_put_int("escala", c["escala"])

  defp agregar_opciones_tipo_campo(propiedades, "referencia", c), do: Map.put(propiedades, "catalogo", c["catalogo"])

  defp agregar_opciones_tipo_campo(propiedades, _tipo, _c), do: propiedades

  defp maybe_put_int(map, _key, val) when val in ["", nil], do: map

  defp maybe_put_int(map, key, val) do
    case Integer.parse(val) do
      {n, _} -> Map.put(map, key, n)
      :error -> map
    end
  end

  defp normalizar_identificador(valor) do
    (valor || "")
    |> String.downcase()
    |> quitar_acentos()
    |> String.replace(~r/[^a-z0-9_]/, "")
    |> String.replace(~r/^[^a-z]+/, "")
    |> String.slice(0, 50)
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
    valor |> String.normalize(:nfd) |> String.replace(~r/\p{Mn}/u, "")
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

  # Mismos chequeos que MetaEstadosAdmin.validar_completo/3 (Fase 1), acá
  # recalculados client-side sobre lo que hay en memoria para dar feedback
  # en vivo antes de someterlo al servidor — la fuente de verdad real sigue
  # siendo la guarda del propio crear_proceso_completo/1.
  defp completo?(campos, estados, transiciones) do
    campos != [] and estados != [] and tiene_alta_o_inicial?(estados, transiciones) and
      Enum.any?(transiciones, &(&1["reglas"] != []))
  end

  defp tiene_alta_o_inicial?(estados, transiciones) do
    Enum.any?(estados, & &1["es_inicial"]) or
      Enum.any?(transiciones, &(&1["accion"] == "alta" and &1["estado_origen"] in [nil, ""]))
  end

  # --- Render --------------------------------------------------------------

  def render(assigns) do
    nombre_sistema_preview = nombre_sistema_desde(assigns.contexto["nombre"])
    nav_preview = componer_nav(assigns.contexto["carpeta_padre"], assigns.contexto["nombre"])

    assigns =
      assigns
      |> assign(:nombre_sistema_preview, nombre_sistema_preview)
      |> assign(:nav_preview, nav_preview)
      |> assign(:tipos_campo, @tipos_campo)
      |> assign(:diagrama, diagrama_mermaid_staged(assigns.estados, assigns.transiciones))
      |> assign(:completo?, completo?(assigns.campos, assigns.estados, assigns.transiciones))

    ~H"""
    <div class="max-w-7xl mx-auto p-6 text-xs font-sans space-y-4">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-lg font-bold text-gray-900">Nuevo catálogo genérico</h1>
          <p class="mt-0.5 text-gray-500">Contexto + Campos + Estados + Transiciones + Reglas, todo junto — nada se guarda hasta "Crear".</p>
        </div>
        <div class="flex gap-2 shrink-0">
          <button type="button" phx-click="cancelar" class="px-4 py-2 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
            Cancelar
          </button>
          <button type="button" phx-click="guardar_borrador"
            title="Guarda lo que llevás armado para retomarlo después, sin crear nada todavía."
            class="px-4 py-2 rounded-lg border border-purple-600 text-purple-700 font-semibold hover:bg-purple-50">
            {if @borrador_id, do: "Actualizar borrador", else: "Guardar borrador"}
          </button>
          <button type="button" phx-click="crear" disabled={!@completo? or !!@contexto_nav_error}
            class="px-4 py-2 rounded-lg bg-purple-600 text-white font-bold hover:bg-purple-700 transition-colors disabled:opacity-40 disabled:cursor-not-allowed">
            Crear Business Process
          </button>
        </div>
      </div>

      <%= if @mensaje do %>
        <div class={[
          "px-3 py-2 rounded-lg font-medium",
          elem(@mensaje, 0) == :ok && "bg-green-50 text-green-700",
          elem(@mensaje, 0) == :error && "bg-red-50 text-red-700"
        ]}>
          {elem(@mensaje, 1)}
        </div>
      <% end %>

      <.motor_stepper pasos={pasos_wizard(@campos, @estados, @transiciones)} />

      <.tabs_motor id="wizard" tabs={[%{key: "config", label: "Configuración"}, %{key: "diagrama", label: "Diagrama"}]} />

      <div id="wizard-panel-config" class="space-y-4">
        <.panel_contexto contexto={@contexto} carpetas={@carpetas} iconos_sugeridos={@iconos_sugeridos}
          nombre_sistema_preview={@nombre_sistema_preview} nav_preview={@nav_preview} nav_error={@contexto_nav_error} />
        <.panel_campos campos={@campos} />
        <.panel_estados estados={@estados} puede_agregar={@campos != []} />
        <.panel_transiciones transiciones={@transiciones} estados={@estados}
          puede_agregar={@estados != [] and tiene_alta_o_inicial?(@estados, @transiciones)} />
      </div>

      <div id="wizard-panel-diagrama" class="hidden">
        <.diagrama_transiciones diagrama={@diagrama} />
      </div>
    </div>

    <.modal_campo :if={@campo_form} form={@campo_form} tipos={@tipos_campo} catalogos={@catalogos_referenciables} />
    <.modal_estado :if={@estado_form} form={@estado_form} iconos_sugeridos={@iconos_sugeridos} />
    <.modal_transicion :if={@transicion_form} form={@transicion_form} estados={@estados} campos={@campos} />
    <.modal_regla :if={@regla_form} form={@regla_form} vocabulario={MetaEstadosAdmin.vocabulario()} />
    """
  end

  # Misma idea que BcMotorLive.diagrama_mermaid/2, pero sobre listas de mapas
  # de string (los estados/transiciones acá todavía no tienen id — son
  # borrador en memoria) en vez de structs de Ecto con id real.
  defp diagrama_mermaid_staged(estados, transiciones) do
    alias_por_nombre = estados |> Enum.with_index(1) |> Map.new(fn {e, i} -> {e["nombre"], "e#{i}"} end)

    declaraciones =
      Enum.map(estados, fn e -> ~s(    state "#{escapar_mermaid(e["nombre"])}" as #{Map.fetch!(alias_por_nombre, e["nombre"])}) end)

    iniciales =
      estados
      |> Enum.filter(& &1["es_inicial"])
      |> Enum.map(&"    [*] --> #{Map.fetch!(alias_por_nombre, &1["nombre"])}")

    arcos =
      Enum.map(transiciones, fn t ->
        origen = if t["estado_origen"] in [nil, ""], do: "[*]", else: Map.get(alias_por_nombre, t["estado_origen"], "?")
        destino = Map.get(alias_por_nombre, t["estado_destino"], "?")
        "    #{origen} --> #{destino} : #{escapar_mermaid(t["accion"])}"
      end)

    estilos =
      estados
      |> Enum.filter(& &1["color"])
      |> Enum.map(&estilo_color(Map.fetch!(alias_por_nombre, &1["nombre"]), &1["color"]))

    (["stateDiagram-v2"] ++ declaraciones ++ iniciales ++ arcos ++ estilos) |> Enum.join("\n")
  end

  defp escapar_mermaid(texto), do: String.replace(texto || "", "\"", "")

  # El color que se elige por Estado se aplica de verdad al nodo del
  # diagrama — Mermaid soporta `style <id> fill:...` igual que en un
  # flowchart. El color de texto se calcula por luminancia (YIQ) para que
  # siga siendo legible sobre cualquier fill, claro u oscuro.
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

  # Mismo orden lógico y mismo componente (<.motor_stepper>) que BcMotorLive
  # (ver pasos_motor/2 ahí) — acá recalculado sobre las listas en memoria en
  # vez de sobre completitud/1, porque todavía no hay nada guardado.
  # "Transiciones" no es parte de completo?/3 (ver arriba), se deriva igual
  # que en BcMotorLive: hay al menos una Y ninguna es un self-loop sin
  # campos editables configurados.
  defp pasos_wizard(campos, estados, transiciones) do
    tiene_transiciones? = transiciones != [] and self_loops_ok?(transiciones)

    [
      {"Campos", campos != []},
      {"Estados", estados != []},
      {"Estado inicial", tiene_alta_o_inicial?(estados, transiciones)},
      {"Transiciones", tiene_transiciones?},
      {"Reglas", Enum.any?(transiciones, &(&1["reglas"] != []))}
    ]
    |> marcar_estado_pasos()
  end

  defp self_loops_ok?(transiciones) do
    transiciones
    |> Enum.filter(&(&1["estado_origen"] not in [nil, ""] and &1["estado_origen"] == &1["estado_destino"]))
    |> Enum.all?(&(&1["campos_editables"] != []))
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

  attr :contexto, :map, required: true
  attr :carpetas, :list, required: true
  attr :iconos_sugeridos, :list, required: true
  attr :nombre_sistema_preview, :string, required: true
  attr :nav_preview, :string, required: true
  attr :nav_error, :string, default: nil

  defp panel_contexto(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Contexto</span>
      </div>
      <form phx-change="validar_contexto" class="grid grid-cols-[110px_1fr] gap-y-1.5 gap-x-2 p-2.5 items-start">
        <label class="font-medium text-gray-900 pt-1">Nombre:</label>
        <div>
          <div class="flex items-center gap-1">
            <span class="border border-gray-200 rounded-lg bg-gray-100 text-gray-500 px-1.5 py-1 select-none">pty_</span>
            <input type="text" name="contexto[nombre]" value={@contexto["nombre"]} required maxlength="45"
              title="Minúsculas, sin acentos ni espacios. Define el nombre de sistema y el segmento final de la Navegación."
              class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 flex-1 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" placeholder="carros" />
          </div>
          <div class="mt-1 bg-purple-50 border border-purple-200 text-purple-700 rounded-lg px-1.5 py-0.5 inline-flex items-center gap-1">
            <span class="text-purple-400">Vista previa:</span>
            <span class="font-mono">{@nombre_sistema_preview}</span>
          </div>
        </div>

        <label class="font-medium text-gray-900 pt-1">Etiqueta:</label>
        <input type="text" name="contexto[etiqueta]" value={@contexto["etiqueta"]} required maxlength="100"
          class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" placeholder="Catálogo de carros" />

        <label class="font-medium text-gray-900 pt-1">Navegación:</label>
        <div>
          <select name="contexto[carpeta_padre]"
            title="El segmento final ya lo definiste en Nombre — acá solo elegís bajo qué carpeta del menú va."
            class="border border-gray-300 rounded-lg text-gray-900 px-2 py-1 w-full focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500">
            <option value="" selected={@contexto["carpeta_padre"] in [nil, ""]}>— Sin carpeta (raíz) —</option>
            <%= for carpeta <- @carpetas do %>
              <option value={carpeta.ruta} selected={@contexto["carpeta_padre"] == carpeta.ruta}>{carpeta.etiqueta}</option>
            <% end %>
          </select>
          <div class={[
            "mt-1 rounded-lg px-1.5 py-0.5 inline-flex items-center gap-1 border",
            @nav_error && "bg-red-50 border-red-200 text-red-700",
            !@nav_error && "bg-purple-50 border-purple-200 text-purple-700"
          ]}>
            <span class={if @nav_error, do: "text-red-400", else: "text-purple-400"}>Vista previa:</span>
            <span class="font-mono">{@nav_preview}</span>
          </div>
          <%= if @nav_error do %>
            <p class="mt-0.5 text-red-600">{@nav_error}</p>
          <% end %>
        </div>

        <label class="font-medium text-gray-900 pt-1">Ícono:</label>
        <div>
          <div class="flex items-center gap-4">
            <input type="hidden" name="contexto[icono]" value={@contexto["icono"]} />
            <button type="button" phx-click={JS.toggle(to: "#selector-iconos-contexto")}
              class="w-6 h-6 flex items-center justify-center border border-gray-300 rounded-lg bg-gray-50 hover:bg-gray-100 text-gray-700" title="Elegir ícono">
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
          <div id="selector-iconos-contexto" class="hidden mt-1 border border-gray-200 rounded-lg bg-white shadow-lg p-1.5 max-w-md">
            <div class="grid grid-cols-10 gap-0.5 max-h-40 overflow-y-auto">
              <%= for icono <- @iconos_sugeridos do %>
                <button type="button" title={icono}
                  phx-click={JS.push("elegir_icono_contexto", value: %{icono: icono}) |> JS.hide(to: "#selector-iconos-contexto")}
                  class={[
                    "w-6 h-6 flex items-center justify-center rounded-lg text-gray-700 hover:bg-purple-50 hover:text-purple-700",
                    @contexto["icono"] == icono && "bg-purple-100 text-purple-700"
                  ]}>
                  <span class="material-symbols-outlined" style="font-size: 16px">{icono}</span>
                </button>
              <% end %>
            </div>
          </div>
        </div>
      </form>
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
          <p class="text-gray-400 mb-2">Todavía no agregaste campos.</p>
        <% else %>
          <table class="min-w-full mb-2">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Nombre</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Etiqueta</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Tipo</th>
                <th class="px-1.5 py-1 border-b border-gray-200"></th>
              </tr>
            </thead>
            <tbody>
              <%= for {c, idx} <- Enum.with_index(@campos) do %>
                <tr class="border-b border-gray-100 hover:bg-gray-50">
                  <td class="px-1.5 py-1 text-gray-900 font-mono">{c["nombre"]}</td>
                  <td class="px-1.5 py-1 text-gray-700">{c["etiqueta"]}</td>
                  <td class="px-1.5 py-1 text-gray-600">{c["tipo"]}</td>
                  <td class="px-1.5 py-1">
                    <button type="button" phx-click="quitar_campo" phx-value-idx={idx} class="text-red-600 hover:text-red-800 text-[11px] font-semibold">Quitar</button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
        <button type="button" phx-click="abrir_form_campo" class="text-purple-700 hover:text-purple-900 font-semibold">+ Agregar campo</button>
      </div>
    </div>
    """
  end

  attr :estados, :list, required: true
  attr :puede_agregar, :boolean, required: true

  defp panel_estados(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Estados</span>
      </div>
      <div class="p-3 pt-4 overflow-x-auto">
        <%= if @estados == [] do %>
          <p class="text-gray-400 mb-2">Todavía no agregaste estados.</p>
        <% else %>
          <table class="min-w-full mb-2">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-1.5 py-1"></th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Nombre</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Inicial</th>
                <th class="px-1.5 py-1 border-b border-gray-200"></th>
              </tr>
            </thead>
            <tbody>
              <%= for {e, idx} <- Enum.with_index(@estados) do %>
                <tr class="border-b border-gray-100 hover:bg-gray-50">
                  <td class="px-1.5 py-1"><span class="inline-block w-2.5 h-2.5 rounded-full" style={"background: #{e["color"] || "#d1d5db"}"}></span></td>
                  <td class="px-1.5 py-1 text-gray-900">{e["nombre"]}</td>
                  <td class="px-1.5 py-1">
                    <%= if e["es_inicial"] do %><span class="text-purple-700 font-semibold">Sí</span><% else %><span class="text-gray-400">—</span><% end %>
                  </td>
                  <td class="px-1.5 py-1">
                    <button type="button" phx-click="quitar_estado" phx-value-idx={idx} class="text-red-600 hover:text-red-800 text-[11px] font-semibold">Quitar</button>
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
  attr :estados, :list, required: true
  attr :puede_agregar, :boolean, required: true

  defp panel_transiciones(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Transiciones</span>
      </div>
      <div class="p-3 pt-4 overflow-x-auto">
        <%= if @transiciones == [] do %>
          <p class="text-gray-400 mb-2">Todavía no agregaste transiciones.</p>
        <% else %>
          <table class="min-w-full mb-2">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Acción</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Origen → Destino</th>
                <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Reglas</th>
                <th class="px-1.5 py-1 border-b border-gray-200"></th>
              </tr>
            </thead>
            <tbody>
              <%= for {t, idx} <- Enum.with_index(@transiciones) do %>
                <tr class="border-b border-gray-100 hover:bg-gray-50 align-top">
                  <td class="px-1.5 py-1.5 text-gray-900 font-mono">{t["accion"]}</td>
                  <td class="px-1.5 py-1.5 text-gray-600">
                    {t["estado_origen"] || "— (alta)"}<span class="text-gray-300 mx-1">→</span>{t["estado_destino"]}
                  </td>
                  <td class="px-1.5 py-1.5">
                    <div class="flex flex-wrap gap-1 mb-1">
                      <%= for {r, ridx} <- Enum.with_index(t["reglas"]) do %>
                        <span class={[
                          "inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[11px] font-mono",
                          r["tipo"] == "pre" && "bg-gray-100 text-gray-700",
                          r["tipo"] == "post" && "bg-purple-50 text-purple-700"
                        ]}>
                          {r["regla"]}
                          <button type="button" phx-click="quitar_regla" phx-value-transicion_idx={idx} phx-value-regla_idx={ridx} class="text-gray-400 hover:text-red-600 leading-none">×</button>
                        </span>
                      <% end %>
                    </div>
                    <button type="button" phx-click="abrir_form_regla" phx-value-transicion_idx={idx} class="text-purple-700 hover:text-purple-900 font-semibold text-[11px]">+ Regla</button>
                  </td>
                  <td class="px-1.5 py-1.5">
                    <button type="button" phx-click="quitar_transicion" phx-value-idx={idx} class="text-red-600 hover:text-red-800 text-[11px] font-semibold">Quitar</button>
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
        <%= if !@puede_agregar do %>
          <span class="text-gray-400 ml-1">(definí un estado inicial primero)</span>
        <% end %>
      </div>
    </div>
    """
  end

  attr :diagrama, :string, required: true

  defp diagrama_transiciones(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Diagrama</span>
      </div>
      <div class="p-3 pt-4">
        <div id="diagrama-nuevo" phx-hook="DiagramaMotor" phx-update="ignore" data-diagrama={@diagrama}
          class="flex items-center justify-center min-h-[80px] text-gray-400">
          Cargando diagrama…
        </div>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :tipos, :list, required: true
  attr :catalogos, :list, required: true

  defp modal_campo(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div class="bg-white rounded-xl shadow-lg max-w-sm w-full p-4 text-xs">
        <h2 class="text-sm font-bold text-gray-900 mb-3">Agregar campo</h2>
        <%= if @form["error"] do %><div class="bg-red-50 text-red-700 rounded-lg px-2 py-1.5 mb-2">{@form["error"]}</div><% end %>
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
              <%= for tipo <- @tipos do %><option value={tipo} selected={@form["tipo"] == tipo}>{tipo}</option><% end %>
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
            <div><label class="block text-gray-700 mb-0.5">longitud</label><input type="number" name="longitud" value={@form["longitud"]} class="w-full border border-gray-300 rounded-lg px-2 py-1" /></div>
            <div><label class="block text-gray-700 mb-0.5">precisión</label><input type="number" name="precision" value={@form["precision"]} class="w-full border border-gray-300 rounded-lg px-2 py-1" /></div>
            <div><label class="block text-gray-700 mb-0.5">escala</label><input type="number" name="escala" value={@form["escala"]} class="w-full border border-gray-300 rounded-lg px-2 py-1" /></div>
          </div>
          <label class="flex items-center gap-1.5">
            <input type="hidden" name="opcional" value="false" />
            <input type="checkbox" name="opcional" value="true" checked={@form["opcional"] == true} class="accent-purple-600" />
            Opcional
          </label>
          <div class="flex justify-end gap-2 pt-2">
            <button type="button" phx-click="cerrar_form_campo" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">Cancelar</button>
            <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">Agregar</button>
          </div>
        </form>
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
        <h2 class="text-sm font-bold text-gray-900 mb-3">Agregar estado</h2>
        <%= if @form["error"] do %><div class="bg-red-50 text-red-700 rounded-lg px-2 py-1.5 mb-2">{@form["error"]}</div><% end %>
        <form phx-submit="guardar_estado" class="space-y-2">
          <div>
            <label class="block text-gray-700 mb-0.5">Nombre</label>
            <input type="text" name="nombre" value={@form["nombre"]} placeholder="Activo" required maxlength="100"
              class="w-full border border-gray-300 rounded-lg px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />
          </div>
          <div class="grid grid-cols-2 gap-2">
            <div><label class="block text-gray-700 mb-0.5">Orden</label><input type="number" name="orden" value={@form["orden"]} required class="w-full border border-gray-300 rounded-lg px-2 py-1.5" /></div>
            <div><label class="block text-gray-700 mb-0.5">Color</label><input type="color" name="color" value={@form["color"]} class="w-full h-[30px] border border-gray-300 rounded-lg px-1 py-0.5" /></div>
          </div>
          <div>
            <label class="block text-gray-700 mb-0.5">Ícono</label>
            <input type="hidden" name="icono" value={@form["icono"]} />
            <button type="button" phx-click={JS.toggle(to: "#selector-iconos-estado-nuevo")}
              class="w-6 h-6 flex items-center justify-center border border-gray-300 rounded-lg bg-gray-50 hover:bg-gray-100 text-gray-700" title="Elegir ícono">
              <%= if @form["icono"] not in [nil, ""] do %>
                <span class="material-symbols-outlined" style="font-size: 16px">{@form["icono"]}</span>
              <% else %>
                <span class="material-symbols-outlined text-gray-400" style="font-size: 16px">apps</span>
              <% end %>
            </button>
            <div id="selector-iconos-estado-nuevo" class="hidden mt-1 border border-gray-200 rounded-lg bg-white shadow-lg p-1.5 max-w-md">
              <div class="grid grid-cols-10 gap-0.5 max-h-40 overflow-y-auto">
                <%= for icono <- @iconos_sugeridos do %>
                  <button type="button" title={icono}
                    phx-click={JS.push("elegir_icono_estado", value: %{icono: icono}) |> JS.hide(to: "#selector-iconos-estado-nuevo")}
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
            <button type="button" phx-click="cerrar_form_estado" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">Cancelar</button>
            <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">Agregar</button>
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
        <h2 class="text-sm font-bold text-gray-900 mb-3">Agregar transición</h2>
        <%= if @form["error"] do %><div class="bg-red-50 text-red-700 rounded-lg px-2 py-1.5 mb-2">{@form["error"]}</div><% end %>
        <form phx-submit="guardar_transicion" class="space-y-2">
          <div>
            <label class="block text-gray-700 mb-0.5">Acción</label>
            <input type="text" name="accion" value={@form["accion"]} placeholder="alta" required maxlength="100"
              class="w-full border border-gray-300 rounded-lg px-2 py-1.5 font-mono focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />
            <p class="mt-0.5 text-[11px] text-gray-500">
              Se guarda en minúsculas. <span class="font-mono">alta</span> (sin origen) y
              <span class="font-mono">guardar</span> (self-loop, mismo origen y destino) son palabras clave que el
              motor reconoce automáticamente — cualquier otro nombre es una transición normal.
            </p>
          </div>
          <div>
            <label class="block text-gray-700 mb-0.5">Etiqueta</label>
            <input type="text" name="etiqueta" value={@form["etiqueta"]} placeholder="Registrar" required maxlength="100"
              class="w-full border border-gray-300 rounded-lg px-2 py-1.5 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-500" />
          </div>
          <div class="grid grid-cols-2 gap-2">
            <div>
              <label class="block text-gray-700 mb-0.5">Origen</label>
              <select name="estado_origen" class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
                <option value="">— (alta, sin origen) —</option>
                <%= for e <- @estados do %><option value={e["nombre"]} selected={@form["estado_origen"] == e["nombre"]}>{e["nombre"]}</option><% end %>
              </select>
            </div>
            <div>
              <label class="block text-gray-700 mb-0.5">Destino</label>
              <select name="estado_destino" required class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
                <option value="">— Elegir —</option>
                <%= for e <- @estados do %><option value={e["nombre"]} selected={@form["estado_destino"] == e["nombre"]}>{e["nombre"]}</option><% end %>
              </select>
            </div>
          </div>
          <%= if @campos != [] do %>
            <div>
              <label class="block text-gray-700 mb-1">Campos editables en esta transición</label>
              <div class="flex flex-col gap-1 max-h-48 overflow-y-auto border border-gray-200 rounded-lg p-1.5">
                <%= for c <- @campos do %>
                  <label class="flex items-center gap-1">
                    <input type="checkbox" name="campos_editables[]" value={c["nombre"]} class="accent-purple-600" />
                    <span class="font-mono truncate">{c["nombre"]}</span>
                  </label>
                <% end %>
              </div>
            </div>
          <% end %>
          <div class="flex justify-end gap-2 pt-2">
            <button type="button" phx-click="cerrar_form_transicion" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">Cancelar</button>
            <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">Agregar</button>
          </div>
        </form>
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
        <p class="text-gray-500 mb-3">Vocabulario cerrado</p>
        <%= if @form.error do %><div class="bg-red-50 text-red-700 rounded-lg px-2 py-1.5 mb-2">{@form.error}</div><% end %>
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
              <%= for campo <- requeridos do %><.campo_param_regla regla={@form.regla} campo={campo} /><% end %>
            </div>
          <% end %>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="cerrar_form_regla" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">Cancelar</button>
            <button type="submit" disabled={!@form.regla} class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700 disabled:opacity-40 disabled:cursor-not-allowed">Agregar</button>
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
        <option value=">">&gt;</option><option value=">=">&gt;=</option><option value="<">&lt;</option>
        <option value="<=">&lt;=</option><option value="==">==</option><option value="!=">!=</option>
      </select>
    </div>
    """
  end

  defp campo_param_regla(%{regla: "mutar_relacionados", campo: "cambio"} = assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-2">
      <div><label class="block text-gray-700 mb-0.5">cambio: campo</label><input type="text" name="params[cambio_campo]" class="w-full border border-gray-300 rounded-lg px-2 py-1" /></div>
      <div><label class="block text-gray-700 mb-0.5">cambio: valor</label><input type="text" name="params[cambio_valor]" class="w-full border border-gray-300 rounded-lg px-2 py-1" /></div>
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
end
