defmodule MetadataAppWeb.FichaLive do
  @moduledoc """
  Ficha 360°: vista de un registro puntual de CUALQUIER catálogo, reusable
  (no específica de "Marcas" ni de ningún catálogo en particular). Reglas del
  patrón, todas ya resueltas por el motor existente — acá solo se componen:

  - Qué se puede CONSULTAR: todos los campos visibles del catálogo
    (`MetaSchemaContext.listar_detalles/1`), como ya hace `CatalogoLive` para
    la grilla.
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

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}

  import Ecto.Query
  import MetadataAppWeb.CampoInputComponents, only: [campo_input: 1]

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.Scope
  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerico}
  alias MetadataApp.MetaStateEngine
  alias MetadataApp.MetaPlantillas
  alias MetadataApp.MetaPlantillas.Formula
  alias MetadataApp.MetaSchema.TransicionEvento
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
        registro = CatalogoGenerico.obtener!(schema_mod, id)

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
  def mount(%{"tabla" => tabla}, _session, socket) do
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

        transicion_alta = if es_detalle?, do: nil, else: MetaStateEngine.transicion_alta(tabla)

        campos_editables =
          if es_detalle?,
            do: [],
            else: tabla |> MetaStateEngine.campos_editables(transicion_alta) |> campos_editables_propios(columnas)

        {:ok,
         socket
         |> assign(:current_page, tabla)
         |> assign(:encontrado?, true)
         |> assign(:modo, :alta)
         |> assign(:tabla, tabla)
         |> assign(:schema_mod, schema_mod)
         |> assign(:header, header)
         |> assign(:es_detalle?, es_detalle?)
         |> assign(:plantilla_preview_id, nil)
         |> assign(:plantilla, MetaPlantillas.obtener_plantilla_publicada(header.id))
         |> assign(:tab, "datos")
         |> assign(:registro, %{})
         |> assign(:columnas, columnas)
         |> assign(:estados_por_id, %{})
         |> assign(:mostrar_estado?, false)
         |> assign(:transicion_edicion, transicion_alta)
         |> assign(:campos_editables, campos_editables)
         |> assign(:otras_transiciones, [])
         |> assign(:relaciones, [])
         |> assign(:relaciones_total, 0)
         |> assign(:historial, [])
         |> assign(:form_values, %{})
         |> assign(:errores_campos, %{})
         |> assign(:error_guardado, nil)
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

  def handle_event("ejecutar_transicion", %{"accion" => accion}, socket) do
    case MetaStateEngine.ejecutar_transicion(socket.assigns.registro, accion, %{}) do
      {:ok, actualizado} ->
        {:noreply,
         socket
         |> assign(:error_guardado, nil)
         |> cargar_registro(actualizado)
         |> put_flash(:info, "Transición ejecutada.")}

      {:error, razon} ->
        {:noreply, assign(socket, :error_guardado, formatear_error(razon))}
    end
  end

  # En modo alta no hay registro que releer — "Actualizar ficha" acá solo
  # limpia el error para que el usuario reintente el alta.
  def handle_event("actualizar_ficha", _params, %{assigns: %{modo: :alta}} = socket) do
    {:noreply, assign(socket, :error_guardado, nil)}
  end

  def handle_event("actualizar_ficha", _params, socket) do
    %{schema_mod: schema_mod, registro: registro} = socket.assigns
    registro_actual = CatalogoGenerico.obtener!(schema_mod, registro.id)

    {:noreply,
     socket
     |> assign(:form_values, %{})
     |> assign(:errores_campos, %{})
     |> assign(:error_guardado, nil)
     |> cargar_registro(registro_actual)}
  end

  # --- Catálogo Maestro-Detalle: Grid Editable del tab "Detalle" ----------
  # Todo el estado interactivo de la grilla (teclado, pegado, validación en
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
  #   %{"renglon_id" => N, "<campo>" => valor}.
  def handle_event("grid_sync", %{"catalogo" => catalogo, "nuevas" => nuevas, "editadas" => editadas}, socket) do
    items_editados = Enum.map(editadas, fn %{"renglon_id" => id, "campos" => campos} -> Map.put(campos, "renglon_id", id) end)

    {:noreply,
     socket
     |> assign(:detalle_renglones_nuevos, Map.put(socket.assigns.detalle_renglones_nuevos, catalogo, limpiar_renglones_vacios(nuevas)))
     |> assign(:detalle_renglones_editados, Map.put(socket.assigns.detalle_renglones_editados, catalogo, items_editados))}
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
  #   grilla para una fila existente es una transición REAL ya configurada
  #   para este catálogo (@otras_transiciones, la misma lista que ya arma
  #   los botones del encabezado), nunca una acción hardcodeada tipo
  #   "cancelar". Es la misma operación que ya hace
  #   CatalogoLive.detalle_modal (checkbox + botón de transición), acá
  #   aplicada a un solo renglón desde la grilla.
  def handle_event("renglon_transicion", %{"catalogo" => catalogo, "renglon_id" => renglon_id, "accion" => accion}, socket) do
    case MetaStateEngine.ejecutar_transicion(socket.assigns.registro, accion, %{}, renglones: %{catalogo => [renglon_id]}) do
      {:ok, actualizado} ->
        socket = cargar_registro(socket, actualizado)

        columnas =
          socket.assigns.catalogos_detalle
          |> Enum.find(%{columnas: []}, &(&1.nombre == catalogo))
          |> Map.get(:columnas)

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
      detalle_renglones_nuevos: renglones_nuevos_grilla,
      detalle_renglones_editados: renglones_editados_grilla,
      transicion_edicion: transicion_edicion
    } = socket.assigns

    renglones_nuevos = Map.new(renglones_nuevos_grilla, fn {catalogo, filas} -> {catalogo, limpiar_renglones_vacios(filas)} end)
    renglones_editados = Map.filter(renglones_editados_grilla, fn {_catalogo, filas} -> filas != [] end)

    hay_renglones_nuevos? = Enum.any?(renglones_nuevos, fn {_catalogo, filas} -> filas != [] end)
    hay_renglones_editados? = map_size(renglones_editados) > 0

    cond do
      map_size(attrs) == 0 and not hay_renglones_nuevos? and not hay_renglones_editados? ->
        {:noreply, socket}

      hay_renglones_editados? and is_nil(transicion_edicion) ->
        {:noreply,
         assign(
           socket,
           :error_guardado,
           "Este catálogo no tiene una transición \"guardar\" configurada — no se pueden editar renglones existentes sin pasar por una transición del encabezado."
         )}

      registro_cambio_de_estado?(schema_mod, registro) ->
        {:noreply,
         assign(socket, :error_guardado, "El estado del registro cambió mientras estabas editando.")}

      true ->
        registro_actual = CatalogoGenerico.obtener!(schema_mod, registro.id)
        guardar_cambios(socket, registro_actual, attrs, renglones_nuevos, renglones_editados, transicion_edicion)
    end
  end

  # @form_values ya es el diff de campos_modificados/3 contra el registro
  # (acá un mapa vacío, no hay registro todavía) — mantenido en vivo por
  # "validar" en cada tecleo, mismo mecanismo que :ver, sin volver a leer
  # el <form> directo.
  defp guardar_alta(socket) do
    %{
      schema_mod: schema_mod,
      tabla: tabla,
      form_values: attrs,
      detalle_renglones_nuevos: renglones_grilla
    } = socket.assigns

    # El hook GridEditable ya descarta filas vacías antes de sincronizar
    # (sincronizarAhora en grid_editable.js) — esto es la misma limpieza
    # defensiva del lado servidor, antes de mandarlo al motor.
    renglones = Map.new(renglones_grilla, fn {catalogo, filas} -> {catalogo, limpiar_renglones_vacios(filas)} end)

    case CatalogoGenerico.crear(schema_mod, attrs, renglones: renglones, contexto: socket.assigns.contexto_auditoria) do
      {:ok, nuevo} ->
        {:noreply, push_navigate(socket, to: "/registro/#{tabla}/#{nuevo.id}")}

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
  # "guardar") y la creación de los renglones NUEVOS en staging viajan en
  # la MISMA Repo.transaction — todo o nada. La creación de renglones
  # nuevos sigue sin pasar por MetaStateEngine.ejecutar_transicion/4
  # porque esa opción solo mueve/edita renglones que YA EXISTEN — no sabe
  # crear ninguno, y tocar el motor para que lo supiera hacer es un cambio
  # más grande que el usuario pidió dejar para después (ver plan). Por eso
  # las reglas PRE/POST de "guardar" ven los renglones EDITADOS (van
  # dentro de la misma transición), pero no los renglones NUEVOS.
  #
  # contexto_auditoria (roadmap #6, ver AuditoriaContexto.desde_socket/1 en
  # mount/3) viaja a CatalogoGenerico.actualizar/3 y .crear_muchos/3 —
  # ejecutar_transicion/4 (R4, renglones editados) no lo necesita, ese
  # camino ya queda registrado por su propio TransicionEvento.
  defp guardar_cambios(socket, registro_actual, attrs, renglones_nuevos, renglones_editados, transicion_edicion) do
    contexto_auditoria = socket.assigns.contexto_auditoria

    resultado =
      Repo.transaction(fn ->
        with {:ok, actualizado} <-
               aplicar_encabezado(registro_actual, attrs, renglones_editados, transicion_edicion, contexto_auditoria),
             {:ok, _creados} <- crear_renglones_nuevos(registro_actual.id, renglones_nuevos, contexto_auditoria) do
          actualizado
        else
          {:error, motivo} -> Repo.rollback(motivo)
        end
      end)

    case resultado do
      {:ok, actualizado} ->
        {:noreply,
         socket
         |> assign(:form_values, %{})
         |> assign(:errores_campos, %{})
         |> assign(:error_guardado, nil)
         |> cargar_registro(actualizado)
         |> put_flash(:info, "Cambios guardados.")}

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
  defp aplicar_encabezado(registro, attrs, renglones_editados, _transicion, contexto_auditoria)
       when map_size(renglones_editados) == 0 do
    actualizar_si_hay_cambios(registro, attrs, contexto_auditoria)
  end

  defp aplicar_encabezado(registro, attrs, renglones_editados, transicion, _contexto_auditoria) do
    MetaStateEngine.ejecutar_transicion(registro, transicion.accion, attrs, renglones: renglones_editados)
  end

  defp actualizar_si_hay_cambios(registro, attrs, _contexto_auditoria) when map_size(attrs) == 0, do: {:ok, registro}

  defp actualizar_si_hay_cambios(registro, attrs, contexto_auditoria),
    do: CatalogoGenerico.actualizar(registro, attrs, contexto_auditoria)

  defp crear_renglones_nuevos(encabezado_id, renglones, contexto_auditoria) do
    Enum.reduce_while(renglones, {:ok, []}, fn {catalogo, items}, {:ok, acc} ->
      case items do
        [] ->
          {:cont, {:ok, acc}}

        _ ->
          detalle_modulo = MetaSchemaContext.modulo_por_nombre(catalogo)
          attrs_items = Enum.map(items, &Map.put(&1, "encabezado_id", encabezado_id))

          case CatalogoGenerico.crear_muchos(detalle_modulo, attrs_items, contexto_auditoria) do
            {:ok, creados} -> {:cont, {:ok, acc ++ creados}}
            {:error, _motivo} = error -> {:halt, error}
          end
      end
    end)
  end

  # Plug decodifica "renglones[0][x]=a&renglones[1][x]=b" como un MAPA con
  # claves "0"/"1" (no una lista) — se reordena acá una sola vez, en el
  # único lugar donde el phx-change de la grilla entra al server.
  # Una fila "vacía" es la fila en blanco que la grilla siempre deja al
  # final (nunca tipeada) o cualquier otra que el usuario vació de vuelta —
  # "false" cuenta como vacío acá porque es lo que manda un checkbox sin
  # marcar, no una respuesta real. El hook GridEditable ya filtra esto de
  # su lado (ver sincronizarAhora), esto es la misma limpieza defensiva del
  # lado servidor.
  defp limpiar_renglones_vacios(filas) do
    Enum.reject(filas, fn fila -> fila == %{} or Enum.all?(Map.values(fila), &(&1 in [nil, "", "false"])) end)
  end

  # Cuenta renglones nuevos + editados en staging — usado para el badge del
  # tab "Detalle" y para habilitar el botón "Guardar".
  defp contar_cambios_detalle(renglones_nuevos, renglones_editados) do
    nuevos = renglones_nuevos |> Map.values() |> Enum.map(&length(limpiar_renglones_vacios(&1))) |> Enum.sum()
    editados = renglones_editados |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    nuevos + editados
  end

  # Chequeo de concurrencia best-effort a nivel de esta pantalla — el motor
  # no tiene optimistic lock (ningún catálogo generado tiene columna
  # `version`/`lock_version` hoy). Comparar el estado_id recién leído contra
  # el que tenía el registro cuando se cargó la ficha cubre el caso real más
  # común (otro usuario/regla movió el estado mientras este usuario editaba)
  # sin inventar una garantía transaccional que el esquema no tiene todavía.
  defp registro_cambio_de_estado?(schema_mod, registro_cargado) do
    actual = CatalogoGenerico.obtener!(schema_mod, registro_cargado.id)
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

    estados_por_id = MetaStateEngine.mapa_nombres_estados(tabla)

    transicion_edicion =
      if es_detalle?, do: nil, else: MetaStateEngine.transicion_guardar(tabla, registro.estado_id)

    campos_editables =
      if es_detalle?,
        do: [],
        else: tabla |> MetaStateEngine.campos_editables(transicion_edicion) |> campos_editables_propios(columnas)

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
        registro
        |> MetaStateEngine.transiciones_disponibles(%{})
        |> Enum.reject(&(&1.accion == "guardar"))
      end

    relaciones = cargar_relaciones(tabla, registro.id)

    # Catálogo Maestro-Detalle: mismo criterio que ya usa CatalogoLive
    # (catalogos_detalle + detalle_renglones) — antes solo se podía
    # agregar un renglón volviendo a la grilla y abriendo el modal viejo;
    # acá la Ficha 360° ya tiene el id real del maestro, así que se
    # resuelve en el lugar, sin ese viaje de ida y vuelta.
    catalogos_detalle = cargar_catalogos_detalle(header.id)
    detalle_renglones = cargar_detalle_renglones(catalogos_detalle, registro.id, estados_por_id)

    socket
    |> assign(:registro, registro)
    |> assign(:plantilla, plantilla_a_mostrar(socket, header.id))
    |> assign(:columnas, columnas)
    |> assign(:estados_por_id, estados_por_id)
    |> assign(:mostrar_estado?, estados_por_id != %{})
    |> assign(:transicion_edicion, transicion_edicion)
    |> assign(:campos_editables, campos_editables)
    |> assign(:otras_transiciones, otras_transiciones)
    |> assign(:relaciones, relaciones)
    |> assign(:relaciones_total, Enum.sum(Enum.map(relaciones, & &1.total)))
    |> assign(:historial, cargar_historial(header.id, registro.id, catalogos_detalle, detalle_renglones))
    |> assign(:catalogos_detalle, catalogos_detalle)
    |> assign(:detalle_renglones, detalle_renglones)
    |> assign(:detalle_renglones_nuevos, %{})
    |> assign(:detalle_renglones_editados, %{})
    |> assign(:detalle_form_error, nil)
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

      %{nombre: h.schema_context_name, etiqueta: h.schema_context_label, columnas: columnas_detalle}
    end)
  end

  defp cargar_detalle_renglones(catalogos_detalle, encabezado_id, estados_por_id) do
    Map.new(catalogos_detalle, fn %{nombre: nombre} ->
      detalle_modulo = MetaSchemaContext.modulo_por_nombre(nombre)

      filas =
        detalle_modulo
        |> CatalogoGenerico.listar(%{"encabezado_id" => encabezado_id})
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
  defp cargar_relaciones(tabla, id) do
    tabla
    |> MetaSchemaContext.listar_dependientes()
    |> Enum.map(&relacion_de(&1, tabla, id))
    |> Enum.reject(&is_nil/1)
  end

  defp relacion_de(dep_nombre, tabla, id) do
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

      %{
        catalogo: dep_nombre,
        etiqueta: dep_header.schema_context_label,
        total: CatalogoGenerico.contar(dep_mod, filtro),
        filas: CatalogoGenerico.listar(dep_mod, filtro, limit: 8)
      }
    end
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
    transiciones =
      from(e in TransicionEvento,
        where: e.meta_schema_header_id == ^header_id and e.registro_id == ^registro_id
      )
      |> Repo.all()
      |> Enum.map(fn e ->
        %{
          origen: :transicion,
          inserted_at: e.inserted_at,
          accion: e.accion,
          estado_origen_id: e.estado_origen_id,
          estado_destino_id: e.estado_destino_id,
          contexto: e.contexto
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
    assigns =
      assign(
        assigns,
        :renglones_nuevos_count,
        contar_cambios_detalle(assigns.detalle_renglones_nuevos, assigns.detalle_renglones_editados)
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

      <div class="bg-white border border-gray-200 rounded-2xl shadow-sm p-5 mb-4">
        <div class="flex items-start justify-between gap-4 flex-wrap">
          <div>
            <div class="text-[11px] font-mono uppercase tracking-wide text-gray-400 mb-1">
              {@header.schema_context_label}<span :if={@modo == :ver}> · ID {@registro.id}</span>
            </div>
            <h1 :if={@modo == :alta} class="text-xl font-bold text-gray-900">Nuevo — {@header.schema_context_label}</h1>
            <h1 :if={@modo == :ver} class="text-xl font-bold text-gray-900">{@header.schema_context_label} #{@registro.id}</h1>
            <div :if={@modo == :ver} class="flex items-center flex-wrap gap-2 mt-2 text-xs text-gray-500">
              <span :if={@mostrar_estado?} class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-purple-50 text-purple-700 font-semibold">
                {Map.get(@estados_por_id, @registro.estado_id) || "—"}
              </span>
              <span>{@relaciones_total} relaciones</span>
            </div>
          </div>

          <div class="flex items-center gap-2 flex-wrap">
            <button :for={t <- @otras_transiciones} type="button"
              phx-click="ejecutar_transicion" phx-value-accion={t.accion} disabled={!t.disponible}
              title={if !t.disponible, do: Enum.map_join(t.razones, "; ", & &1.mensaje)}
              class={[
                "px-3 py-1.5 rounded-lg text-xs font-semibold transition-colors border",
                t.disponible && "border-gray-300 text-gray-700 hover:bg-gray-50",
                !t.disponible && "border-gray-200 text-gray-300 cursor-not-allowed"
              ]}>
              {t.etiqueta}
            </button>

            <button :if={@es_detalle?} type="button" disabled title="Los campos de un renglón de catálogo detalle se editan mediante una transición del maestro"
              class="px-3 py-1.5 rounded-lg text-xs font-semibold border border-gray-200 text-gray-300 cursor-not-allowed">
              Editar
            </button>

            <div :if={!@es_detalle? and (@campos_editables != [] or @catalogos_detalle != [])} class="flex items-center gap-2">
              <span :if={@modo == :ver and map_size(@form_values) + @renglones_nuevos_count > 0}
                class="text-xs text-purple-700 font-semibold whitespace-nowrap">
                {map_size(@form_values) + @renglones_nuevos_count} cambio{if map_size(@form_values) + @renglones_nuevos_count == 1, do: "", else: "s"} sin guardar
              </span>
              <.link :if={@modo == :alta} navigate={@header.schema_context_nav}
                class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 text-xs font-semibold hover:bg-gray-50">
                Cancelar
              </.link>
              <button :if={@modo == :ver} type="button" phx-click="cancelar_edicion" disabled={map_size(@form_values) == 0}
                class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 text-xs font-semibold hover:bg-gray-50 disabled:opacity-40 disabled:cursor-not-allowed">
                Cancelar
              </button>
              <button type="button" phx-click="guardar"
                disabled={@modo == :ver and map_size(@form_values) == 0 and @renglones_nuevos_count == 0}
                class="px-3 py-1.5 rounded-lg bg-purple-600 text-white text-xs font-semibold hover:bg-purple-700 disabled:bg-gray-200 disabled:text-gray-400 disabled:cursor-not-allowed">
                {etiqueta_guardar(@transicion_edicion)}
              </button>
            </div>
          </div>
        </div>

        <div :if={@error_guardado} class="mt-3 bg-red-50 text-red-700 text-xs rounded-lg px-3 py-2 flex items-center justify-between gap-3">
          <span>{@error_guardado}</span>
          <button type="button" phx-click="actualizar_ficha" class="font-semibold whitespace-nowrap hover:underline">
            Actualizar ficha
          </button>
        </div>
      </div>

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
        plantilla={@plantilla} relaciones={@relaciones} estados_por_id={@estados_por_id}
        edicion={%{valores: @form_values, errores: @errores_campos, contexto: contexto_actual(assigns[:current_scope])}} />
      <.tab_relaciones :if={@tab == "relaciones"} relaciones={@relaciones} />
      <.tab_historial :if={@tab == "historial"} historial={@historial} estados_por_id={@estados_por_id} />
      <.tab_detalle :if={@tab == "detalle"} modo={@modo} catalogos_detalle={@catalogos_detalle} detalle_renglones={@detalle_renglones}
        otras_transiciones={@otras_transiciones} detalle_form_error={@detalle_form_error} estados_por_id={@estados_por_id} />
    </div>
    """
  end

  attr :columnas, :list, required: true
  attr :registro, :map, required: true
  attr :campos_editables, :list, required: true
  attr :plantilla, :any, default: nil
  attr :relaciones, :list, default: []
  attr :estados_por_id, :map, default: %{}
  attr :edicion, :map, required: true

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

  defp tab_datos(assigns) do
    ~H"""
    <form id="form-ficha-datos" phx-change="validar" phx-submit="guardar" class="space-y-4">
      <div :if={map_size(@edicion.errores) > 0} class="bg-red-50 text-red-700 text-xs rounded-lg px-3 py-2">
        No se pudo guardar: revisá los campos marcados en rojo.
      </div>
      <.nodo_plantilla :for={nodo <- @plantilla.definicion["hijos"]} nodo={nodo}
        columnas={@columnas} registro={@registro} campos_editables={@campos_editables} relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} />
      <p :if={@plantilla.definicion["hijos"] == []} class="px-4 py-8 text-center text-gray-400 text-sm bg-white border border-gray-200 rounded-xl">
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
      relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} />
    """
  end

  attr :nodo, :map, required: true
  attr :columnas, :list, required: true
  attr :registro, :map, required: true
  attr :campos_editables, :list, required: true
  attr :relaciones, :list, required: true
  attr :estados_por_id, :map, required: true
  attr :edicion, :map, required: true

  # "visible: false" oculta la sección entera (y lo que tenga adentro) en la
  # Ficha 360° — la propiedad la pone/quita quien diseña la plantilla desde
  # el Constructor, acá solo se respeta. Distinto de "condicion" (dinámica,
  # evaluada contra el registro): esto es un apagador fijo, manual.
  defp nodo_plantilla_render(%{nodo: %{"tipo" => "seccion", "propiedades" => %{"visible" => false}}} = assigns), do: ~H""

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "seccion", "propiedades" => %{"colapsable" => true}}} = assigns) do
    assigns = assign(assigns, :padding, padding_seccion(assigns.nodo))

    ~H"""
    <details class="bg-white border border-gray-200 rounded-xl overflow-hidden" open>
      <summary class={["cursor-pointer bg-gray-50 border-b border-gray-100 list-none", @padding]} style="list-style: none">
        <span class="font-bold text-gray-700 text-sm">
          <span :if={@nodo["propiedades"]["icono"] not in [nil, ""]}>{@nodo["propiedades"]["icono"]} </span>{@nodo["propiedades"]["titulo"]}
        </span>
        <div :if={@nodo["propiedades"]["descripcion"] not in [nil, ""]} class="text-xs text-gray-400 mt-0.5 font-normal">{@nodo["propiedades"]["descripcion"]}</div>
      </summary>
      <.nodo_plantilla :for={hijo <- @nodo["hijos"]} nodo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables} relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} />
    </details>
    """
  end

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "seccion"}} = assigns) do
    assigns = assign(assigns, :padding, padding_seccion(assigns.nodo))

    ~H"""
    <div class="bg-white border border-gray-200 rounded-xl overflow-hidden">
      <div class={["border-b border-gray-100 bg-gray-50", @padding]}>
        <div class="font-bold text-gray-700 text-sm">
          <span :if={@nodo["propiedades"]["icono"] not in [nil, ""]}>{@nodo["propiedades"]["icono"]} </span>{@nodo["propiedades"]["titulo"]}
        </div>
        <div :if={@nodo["propiedades"]["descripcion"] not in [nil, ""]} class="text-xs text-gray-400 mt-0.5">{@nodo["propiedades"]["descripcion"]}</div>
      </div>
      <.nodo_plantilla :for={hijo <- @nodo["hijos"]} nodo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables} relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} />
    </div>
    """
  end

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "fila"}} = assigns) do
    n = max(length(assigns.nodo["hijos"]), 1)
    assigns = assign(assigns, :estilo_grid, "display:grid; grid-template-columns: repeat(#{n}, minmax(0, 1fr)); gap: 12px")

    ~H"""
    <div style={@estilo_grid}>
      <.nodo_plantilla :for={hijo <- @nodo["hijos"]} nodo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables} relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} />
    </div>
    """
  end

  defp nodo_plantilla_render(%{nodo: %{"tipo" => "columna"}} = assigns) do
    ~H"""
    <div class="flex flex-col gap-3">
      <.nodo_plantilla :for={hijo <- @nodo["hijos"]} nodo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables} relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} />
    </div>
    """
  end

  # Contenedor visual simple, sin encabezado — a diferencia de "seccion" no
  # tiene título/descripción, solo agrupa visualmente con borde + espaciado.
  defp nodo_plantilla_render(%{nodo: %{"tipo" => "panel"}} = assigns) do
    assigns = assign(assigns, :padding, padding_seccion(assigns.nodo))

    ~H"""
    <div class={["bg-white border border-gray-200 rounded-xl flex flex-col gap-3", @padding]}>
      <.nodo_plantilla :for={hijo <- @nodo["hijos"]} nodo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables} relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} />
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
        <div class="flex flex-col gap-3">
          <.nodo_plantilla :for={hijo <- pestana["hijos"]} nodo={hijo} columnas={@columnas} registro={@registro} campos_editables={@campos_editables} relaciones={@relaciones} estados_por_id={@estados_por_id} edicion={@edicion} />
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
  # campo del formulario.
  defp nodo_plantilla_render(%{nodo: %{"tipo" => "campo_calculado"}} = assigns) do
    valores = valores_efectivos(assigns.columnas, assigns.registro, assigns.edicion.valores, assigns.edicion.contexto)
    formula = assigns.nodo["propiedades"]["formula"] || ""
    resultado = formula |> Formula.evaluar(valores) |> formatear_calculado(assigns.nodo["propiedades"])
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
    assigns = assign(assigns, :r, r)

    ~H"""
    <.tabla_relacion :if={@r} r={@r} titulo={@nodo["propiedades"]["titulo"]} />
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

  defp nodo_plantilla_render(assigns), do: ~H""

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

  # Un "IF ... THEN ... ELSE ..." puede devolver texto (ej. "Disponible" /
  # "Agotado") en vez de un número — Formula.evaluar/2 ahora puede dar
  # cualquiera de los dos, así que este clause tiene que ir ANTES del
  # numérico (que asume que puede multiplicar el resultado).
  defp formatear_calculado({:ok, texto}, _propiedades) when is_binary(texto), do: texto

  defp formatear_calculado({:ok, numero}, propiedades) when is_number(numero) do
    decimales =
      case Integer.parse(to_string(propiedades["decimales"] || "2")) do
        {n, _} when n in 0..10 -> n
        _ -> 2
      end

    :erlang.float_to_binary(numero * 1.0, decimals: decimales)
  end

  defp formatear_calculado({:error, _motivo}, _propiedades), do: "—"

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
        registro = CatalogoGenerico.obtener!(modulo, id)
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

  # Edición en el lugar, siempre: si el campo es editable, la columna de
  # "valor" ya ES el input real (campo_input/1, el mismo que comparten
  # "+ Agregar renglón" y el Constructor), sin ningún paso previo de
  # "Editar" — el campo que no es editable simplemente sigue de solo
  # lectura al lado, nunca se deshabilita en masa nada.
  defp campo_row(assigns) do
    editable? = assigns.col.schema_context_field in assigns.campos_editables
    campo_atom = String.to_existing_atom(assigns.col.schema_context_field)

    valor_actual = Map.get(assigns.registro, campo_atom)

    valor_mostrado =
      Map.get(assigns.edicion.valores, assigns.col.schema_context_field, to_string(valor_actual))

    errores_campo = Map.get(assigns.edicion.errores, campo_atom)

    assigns =
      assigns
      |> assign(:editable?, editable?)
      |> assign(:valor_actual, valor_actual)
      |> assign(:valor_mostrado, valor_mostrado)
      |> assign(:errores_campo, errores_campo)

    ~H"""
    <div class="flex items-center gap-3 px-4 py-2.5 border-b border-gray-100 last:border-b-0 text-sm">
      <span class="w-5 flex-shrink-0 text-gray-400 self-start mt-0.5">
        <svg :if={@editable?} width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="text-purple-600">
          <path d="M12 20h9" /><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" />
        </svg>
        <svg :if={!@editable?} width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <rect x="4" y="10" width="16" height="11" rx="2" /><path d="M8 10V7a4 4 0 0 1 8 0v3" />
        </svg>
      </span>
      <span class="w-56 flex-shrink-0 text-gray-500 self-start mt-0.5">
        {@col.schema_context_properties["etiqueta"]}
        <span :if={@editable? and @col.schema_context_properties["tipo"] != "boolean"} class="text-red-500">*</span>
      </span>

      <div :if={@editable?} class="flex-1 min-w-0">
        <.campo_input columna={@col} valor={@valor_mostrado} mostrar_etiqueta={false} />
        <p :if={@errores_campo} class="text-red-600 text-xs mt-1">{Enum.join(@errores_campo, "; ")}</p>
      </div>
      <span :if={!@editable?} class="text-gray-900 font-medium truncate">
        {(@valor_actual not in [nil, ""] && @valor_actual) || "—"}
      </span>
    </div>
    """
  end

  attr :relaciones, :list, required: true

  defp tab_relaciones(assigns) do
    ~H"""
    <div class="space-y-4">
      <.tabla_relacion :for={r <- @relaciones} r={r} titulo={"#{r.etiqueta} (#{r.total})"} />
      <p :if={@relaciones == []} class="text-center text-gray-400 text-sm py-8">Ningún catálogo depende de este registro.</p>
    </div>
    """
  end

  attr :r, :map, required: true
  attr :titulo, :string, required: true

  defp tabla_relacion(assigns) do
    ~H"""
    <div class="bg-white border border-gray-200 rounded-xl overflow-hidden">
      <div class="flex items-center justify-between px-4 py-2.5 border-b border-gray-100 bg-gray-50">
        <span class="font-bold text-gray-700 text-sm">{@titulo}</span>
      </div>
      <table class="min-w-full text-xs">
        <tbody class="divide-y divide-gray-50">
          <tr :for={fila <- @r.filas} class="hover:bg-purple-50/60">
            <td class="px-4 py-1.5 text-gray-500 w-16">#{fila.id}</td>
            <td class="px-4 py-1.5 text-right">
              <.link navigate={"/registro/#{@r.catalogo}/#{fila.id}"} class="text-purple-700 font-semibold hover:underline">
                Ver ficha
              </.link>
            </td>
          </tr>
          <tr :if={@r.filas == []}>
            <td class="px-4 py-4 text-center text-gray-400" colspan="2">Sin registros todavía.</td>
          </tr>
        </tbody>
      </table>
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

  # Una sola grilla por catálogo detalle (Grid Editable Empresarial, ver
  # docs/catalogo-maestro-detalle-requerimientos.md Fase 6/Grid Editable) —
  # renglones ya persistidos y renglones nuevos conviven en la misma tabla:
  # el hook JS GridEditableComponents.grid/1 se encarga de mostrarlos, dejar
  # tipear filas nuevas al final, y ofrecer las transiciones disponibles
  # (@otras_transiciones) como acción por fila para un renglón ya
  # persistido — R12 sigue intacto (nunca se edita/borra un renglón
  # directo, esa transición es la única forma real de tocarlo).
  defp tab_detalle(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="text-xs text-purple-700 bg-purple-50 rounded-lg px-3 py-2">
        Escribí directo en la tabla, o pegá filas copiadas de Excel — se guarda todo junto con el resto de los cambios, al hacer clic en "Guardar" arriba.
      </div>
      <div :if={@detalle_form_error} class="bg-red-50 text-red-700 text-xs rounded-lg px-3 py-2">{@detalle_form_error}</div>

      <div :for={cat <- @catalogos_detalle} class="bg-white border border-gray-200 rounded-xl overflow-hidden">
        <div class="px-4 py-2.5 border-b border-gray-100 bg-gray-50">
          <span class="font-bold text-gray-700 text-sm">{cat.etiqueta}</span>
        </div>

        <GridEditableComponents.grid id={"grid-#{cat.nombre}"} catalogo={cat.nombre} columnas={cat.columnas}
          filas_existentes={Map.get(@detalle_renglones, cat.nombre, [])} transiciones_disponibles={@otras_transiciones}
          estados_por_id={@estados_por_id} />
      </div>
    </div>
    """
  end
end
