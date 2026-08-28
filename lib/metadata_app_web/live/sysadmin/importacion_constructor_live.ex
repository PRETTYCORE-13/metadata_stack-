defmodule MetadataAppWeb.Sysadmin.ImportacionConstructorLive do
  @moduledoc """
  Pestaña "Importación" del Motor del catálogo (BC) — configurar qué
  plantillas de importación Excel existen para este catálogo: qué campos
  ofrece cada una, en qué orden, cuáles son obligatorios, y (para campos
  `referencia`) qué campo del catálogo destino sirve para resolverlos por
  valor de negocio en vez de id interno. La ejecución real (descargar,
  llenar, subir, validar, confirmar) vive en `CatalogoLive` — acá solo se
  configura, mismo criterio que "Vista Post"/PlantillaConstructorLive
  configura las plantillas que `FichaLive` renderiza.

  Fase 2 del módulo de Importación: si el catálogo tiene detalles reales
  (`MetaImportacionDatos.catalogos_detalle_disponibles/1`), el asistente
  suma un paso para activarlos y elegir sus propios campos, más el campo
  identificador del encabezado (ej. Folio) que vincula las hojas — ver
  moduledoc de `MetaImportacionDatos`. Un catálogo sin detalles ni
  siquiera ve ese paso con contenido (queda un aviso corto). Fase 3
  (multinivel) queda para cuando haga falta — hoy alcanza con 1 nivel,
  que es el que soporta la plataforma.
  """

  use MetadataAppWeb, :live_view_admin

  on_mount {MetadataAppWeb.UsuarioAuth, :mount_current_scope}
  on_mount {MetadataAppWeb.Hooks.Autorizacion, {"sysadmin_bc", "editar"}}

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaImportacionDatos

  # Ruta propia, mismo criterio que PlantillaConstructorLive (sigue
  # existiendo además del tab embebido, por si algo enlaza directo).
  def mount(%{"nombre" => nombre}, _session, socket) do
    montar(socket, nombre, embebido?: false)
  end

  # Embebido dentro del tab "Importación" de BcMotorLive vía live_render/3
  # — mismo mecanismo que "postview"/PlantillaConstructorLive: `nombre`
  # viaja por `session`, nunca por `params` (un hijo montado así siempre
  # recibe `:not_mounted_at_router`).
  def mount(_params, %{"nombre" => nombre}, socket) do
    montar(socket, nombre, embebido?: true)
  end

  defp montar(socket, nombre, embebido?: embebido?) do
    socket = socket |> assign(:sidebar_open, false) |> assign(:current_page, "sysadmin") |> assign(:embebido?, embebido?)

    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        {:ok, assign(socket, :encontrado?, false)}

      header ->
        {:ok,
         socket
         |> assign(:encontrado?, true)
         |> assign(:header, header)
         |> assign(:campos_disponibles, MetaImportacionDatos.campos_disponibles(nombre))
         |> assign(:detalles_disponibles, MetaImportacionDatos.catalogos_detalle_disponibles(header.id))
         |> assign(:plantillas, MetaImportacionDatos.listar_plantillas(header.id))
         |> assign(:editor, nil)}
    end
  end

  # --- Lista de plantillas -------------------------------------------------

  def handle_event("nueva_plantilla", _params, socket) do
    editor = editor_inicial(socket.assigns.header, socket.assigns.campos_disponibles, socket.assigns.detalles_disponibles)
    {:noreply, assign(socket, :editor, editor)}
  end

  def handle_event("editar_plantilla", %{"id" => id}, socket) do
    plantilla = Enum.find(socket.assigns.plantillas, &(&1.id == String.to_integer(id)))
    editor = editor_desde_plantilla(plantilla, socket.assigns.campos_disponibles, socket.assigns.detalles_disponibles)
    {:noreply, assign(socket, :editor, editor)}
  end

  def handle_event("cerrar_editor", _params, socket) do
    {:noreply, assign(socket, :editor, nil)}
  end

  def handle_event("activar_plantilla", %{"id" => id}, socket) do
    plantilla = Enum.find(socket.assigns.plantillas, &(&1.id == String.to_integer(id)))
    {:ok, _} = MetaImportacionDatos.activar(plantilla)
    {:noreply, recargar(socket)}
  end

  def handle_event("desactivar_plantilla", %{"id" => id}, socket) do
    plantilla = Enum.find(socket.assigns.plantillas, &(&1.id == String.to_integer(id)))
    {:ok, _} = MetaImportacionDatos.desactivar(plantilla)
    {:noreply, recargar(socket)}
  end

  def handle_event("eliminar_plantilla", %{"id" => id}, socket) do
    plantilla = Enum.find(socket.assigns.plantillas, &(&1.id == String.to_integer(id)))
    {:ok, _} = MetaImportacionDatos.eliminar_plantilla(plantilla)
    {:noreply, socket |> recargar() |> put_flash(:info, "Plantilla \"#{plantilla.nombre}\" eliminada.")}
  end

  # --- Asistente (1: campos encabezado · 2: detalles · 3: vista previa) ----

  def handle_event("wizard_cambiar", params, socket) do
    editor = socket.assigns.editor

    editor =
      editor
      |> Map.put("nombre", Map.get(params, "nombre", editor["nombre"]))
      |> Map.put("descripcion", Map.get(params, "descripcion", editor["descripcion"]))
      |> Map.put("elegidos", elegidos_desde_params(Map.get(params, "elegidos"), editor["elegidos"]))
      |> Map.put("campo_identificador_encabezado", Map.get(params, "campo_identificador_encabezado", editor["campo_identificador_encabezado"]))
      |> Map.put("detalles", detalles_desde_params(Map.get(params, "detalles"), editor["detalles"]))
      |> Map.put("error", nil)

    {:noreply, assign(socket, :editor, editor)}
  end

  # "Marcar todos"/"Desmarcar todos" — mismo criterio de encabezado y de
  # cada detalle por separado (marcar todos de Productos no toca Pagos).
  def handle_event("wizard_marcar_todos", %{"scope" => "encabezado", "valor" => valor}, socket) do
    marcar? = valor == "true"
    elegidos = Enum.map(socket.assigns.editor["elegidos"], &Map.put(&1, "incluido", marcar?))
    {:noreply, assign(socket, :editor, Map.put(socket.assigns.editor, "elegidos", elegidos))}
  end

  def handle_event("wizard_marcar_todos", %{"scope" => "detalle", "catalogo" => catalogo, "valor" => valor}, socket) do
    marcar? = valor == "true"

    detalles =
      Enum.map(socket.assigns.editor["detalles"], fn d ->
        if d["catalogo"] == catalogo do
          %{d | "elegidos" => Enum.map(d["elegidos"], &Map.put(&1, "incluido", marcar?))}
        else
          d
        end
      end)

    {:noreply, assign(socket, :editor, Map.put(socket.assigns.editor, "detalles", detalles))}
  end

  # Reordenar (hook ListaOrdenable, mismo patrón que la tabla de Campos de
  # BcMotorLive) — solo tiene sentido entre los YA incluidos del
  # encabezado (no hay drag-and-drop para los campos de un detalle, menos
  # crítico ahí — se respeta el orden natural del catálogo).
  def handle_event("wizard_reordenar", %{"id" => campo, "index" => index}, socket) do
    elegidos = socket.assigns.editor["elegidos"]
    incluidos = Enum.filter(elegidos, & &1["incluido"])
    no_incluidos = Enum.reject(elegidos, & &1["incluido"])

    item = Enum.find(incluidos, &(&1["campo"] == campo))
    nuevo_orden_incluidos = incluidos |> List.delete(item) |> List.insert_at(index, item)

    editor = Map.put(socket.assigns.editor, "elegidos", nuevo_orden_incluidos ++ no_incluidos)
    {:noreply, assign(socket, :editor, editor)}
  end

  def handle_event("wizard_ir_paso", %{"paso" => paso}, socket) do
    paso = String.to_integer(paso)
    editor = socket.assigns.editor
    motivo_detalles = paso == 3 && validar_detalles(editor)

    cond do
      paso == 3 and Enum.all?(editor["elegidos"], &(!&1["incluido"])) ->
        {:noreply, assign(socket, :editor, Map.put(editor, "error", "Elegí al menos un campo del encabezado para incluir en la plantilla."))}

      motivo_detalles ->
        {:noreply, assign(socket, :editor, Map.put(editor, "error", motivo_detalles))}

      true ->
        {:noreply, assign(socket, :editor, Map.put(editor, "paso", paso))}
    end
  end

  def handle_event("guardar_plantilla", _params, socket) do
    editor = socket.assigns.editor
    header = socket.assigns.header
    motivo_detalles = validar_detalles(editor)

    cond do
      String.trim(editor["nombre"]) == "" ->
        {:noreply, assign(socket, :editor, Map.put(editor, "error", "El nombre no puede quedar vacío."))}

      Enum.all?(editor["elegidos"], &(!&1["incluido"])) ->
        {:noreply, assign(socket, :editor, Map.put(editor, "error", "Elegí al menos un campo del encabezado para incluir en la plantilla."))}

      motivo_detalles ->
        {:noreply, assign(socket, :editor, Map.put(editor, "error", motivo_detalles))}

      true ->
        definicion = %{
          "campos" => campos_a_definicion(editor["elegidos"]),
          "campo_identificador_encabezado" => editor["campo_identificador_encabezado"],
          "detalles" =>
            editor["detalles"]
            |> Enum.filter(& &1["activo"])
            |> Enum.map(fn d -> %{"catalogo" => d["catalogo"], "activo" => true, "campos" => campos_a_definicion(d["elegidos"])} end)
        }

        attrs = %{"nombre" => editor["nombre"], "descripcion" => editor["descripcion"], "definicion" => definicion}

        resultado =
          case editor["id"] do
            nil -> MetaImportacionDatos.crear_plantilla(header.id, attrs)
            id -> MetaImportacionDatos.actualizar_plantilla(MetaImportacionDatos.obtener_plantilla!(id), attrs)
          end

        case resultado do
          {:ok, _plantilla} ->
            {:noreply, socket |> assign(:editor, nil) |> recargar() |> put_flash(:info, "Plantilla guardada.")}

          {:error, changeset} ->
            {:noreply, assign(socket, :editor, Map.put(editor, "error", MetadataApp.MetaErrores.resumen(changeset)))}
        end
    end
  end

  # --- Helpers privados -----------------------------------------------------

  defp recargar(socket) do
    assign(socket, :plantillas, MetaImportacionDatos.listar_plantillas(socket.assigns.header.id))
  end

  # Un detalle activo sin ningún campo incluido no tiene sentido (una hoja
  # vacía), y ningún detalle activo puede vincularse sin un campo
  # identificador de encabezado elegido (ver moduledoc de
  # MetaImportacionDatos) — nil si todo está bien.
  defp validar_detalles(editor) do
    detalles_activos = Enum.filter(editor["detalles"], & &1["activo"])

    cond do
      detalles_activos == [] ->
        nil

      editor["campo_identificador_encabezado"] in [nil, ""] ->
        "Elegí el campo identificador del encabezado (ej. Folio) para poder vincular los detalles."

      Enum.any?(detalles_activos, &Enum.all?(&1["elegidos"], fn c -> !c["incluido"] end)) ->
        "Cada detalle activado necesita al menos un campo incluido."

      true ->
        nil
    end
  end

  defp campos_a_definicion(elegidos) do
    elegidos
    |> Enum.filter(& &1["incluido"])
    |> Enum.with_index(1)
    |> Enum.map(fn {item, orden} ->
      %{"campo" => item["campo"], "obligatorio" => item["obligatorio"], "orden" => orden, "campo_identificador" => item["campo_identificador"]}
    end)
  end

  defp editor_inicial(header, campos_disponibles, detalles_disponibles) do
    %{
      "id" => nil,
      "paso" => 1,
      "nombre" => "",
      "descripcion" => "",
      "elegidos" => elegidos_iniciales(campos_disponibles),
      "campo_identificador_encabezado" => MetaImportacionDatos.sugerir_campo_identificador(header.schema_context_name),
      "detalles" => Enum.map(detalles_disponibles, &detalle_inicial(&1, nil)),
      "error" => nil
    }
  end

  defp editor_desde_plantilla(plantilla, campos_disponibles, detalles_disponibles) do
    guardados = Map.new(plantilla.definicion["campos"] || [], &{&1["campo"], &1})
    nombres_disponibles = MapSet.new(campos_disponibles, & &1.campo)

    elegidos_guardados =
      guardados
      |> Enum.filter(fn {campo, _def} -> MapSet.member?(nombres_disponibles, campo) end)
      |> Enum.sort_by(fn {_campo, def} -> def["orden"] end)
      |> Enum.map(fn {campo, def} ->
        %{"campo" => campo, "incluido" => true, "obligatorio" => def["obligatorio"] != false, "campo_identificador" => def["campo_identificador"]}
      end)

    campos_sin_elegir =
      campos_disponibles
      |> Enum.reject(&Map.has_key?(guardados, &1.campo))
      |> Enum.map(&%{"campo" => &1.campo, "incluido" => false, "obligatorio" => &1.obligatorio_default, "campo_identificador" => nil})

    detalles_guardados = Map.new(plantilla.definicion["detalles"] || [], &{&1["catalogo"], &1})

    %{
      "id" => plantilla.id,
      "paso" => 1,
      "nombre" => plantilla.nombre,
      "descripcion" => plantilla.descripcion || "",
      "elegidos" => elegidos_guardados ++ campos_sin_elegir,
      "campo_identificador_encabezado" => plantilla.definicion["campo_identificador_encabezado"],
      "detalles" => Enum.map(detalles_disponibles, &detalle_inicial(&1, Map.get(detalles_guardados, &1.catalogo))),
      "error" => nil
    }
  end

  defp elegidos_iniciales(campos_disponibles) do
    Enum.map(campos_disponibles, fn c ->
      %{"campo" => c.campo, "incluido" => false, "obligatorio" => c.obligatorio_default, "campo_identificador" => nil}
    end)
  end

  # `guardado` es el bloque de plantilla.definicion["detalles"] para este
  # catálogo (nil si nunca se activó) — arma el mismo shape de "elegidos"
  # que usa el encabezado, para reusar fila_campo/1 y elegidos_desde_params/2
  # tal cual.
  defp detalle_inicial(%{catalogo: catalogo, etiqueta: etiqueta}, nil) do
    %{"catalogo" => catalogo, "etiqueta" => etiqueta, "activo" => false, "elegidos" => elegidos_iniciales(MetaImportacionDatos.campos_disponibles(catalogo))}
  end

  defp detalle_inicial(%{catalogo: catalogo, etiqueta: etiqueta}, guardado) do
    campos_disponibles = MetaImportacionDatos.campos_disponibles(catalogo)
    guardados = Map.new(guardado["campos"] || [], &{&1["campo"], &1})

    elegidos =
      Enum.map(campos_disponibles, fn c ->
        case Map.get(guardados, c.campo) do
          nil -> %{"campo" => c.campo, "incluido" => false, "obligatorio" => c.obligatorio_default, "campo_identificador" => nil}
          def -> %{"campo" => c.campo, "incluido" => true, "obligatorio" => def["obligatorio"] != false, "campo_identificador" => def["campo_identificador"]}
        end
      end)

    %{"catalogo" => catalogo, "etiqueta" => etiqueta, "activo" => true, "elegidos" => elegidos}
  end

  defp elegidos_desde_params(nil, elegidos_actuales), do: elegidos_actuales

  defp elegidos_desde_params(elegidos_params, elegidos_actuales) do
    Enum.map(elegidos_actuales, fn item ->
      case Map.get(elegidos_params, item["campo"]) do
        nil ->
          item

        v ->
          %{
            "campo" => item["campo"],
            "incluido" => v["incluido"] == "true",
            "obligatorio" => v["obligatorio"] == "true",
            "campo_identificador" => Map.get(v, "campo_identificador", item["campo_identificador"])
          }
      end
    end)
  end

  defp detalles_desde_params(nil, detalles_actuales), do: detalles_actuales

  defp detalles_desde_params(detalles_params, detalles_actuales) do
    Enum.map(detalles_actuales, fn detalle ->
      case Map.get(detalles_params, detalle["catalogo"]) do
        nil ->
          detalle

        dp ->
          %{
            detalle
            | "activo" => Map.get(dp, "activo") == "true",
              "elegidos" => elegidos_desde_params(Map.get(dp, "elegidos"), detalle["elegidos"])
          }
      end
    end)
  end

  # --- Render ---------------------------------------------------------------

  def render(%{encontrado?: false} = assigns) do
    ~H"""
    <div class="p-6 text-gray-500">Catálogo no encontrado.</div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class={["space-y-4", !@embebido? && "p-6 max-w-5xl"]}>
      <h1 :if={!@embebido?} class="text-base font-bold text-gray-900">Importación — {@header.schema_context_label}</h1>

      <%= if @editor do %>
        <.editor_plantilla editor={@editor} campos_disponibles={@campos_disponibles} />
      <% else %>
        <.lista_plantillas plantillas={@plantillas} />
      <% end %>
    </div>
    """
  end

  attr :plantillas, :list, required: true

  defp lista_plantillas(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-500">Plantillas de importación</span>
      </div>
      <div class="p-3 pt-4">
        <p :if={@plantillas == []} class="text-gray-400 mb-2">
          Este catálogo todavía no tiene ninguna plantilla de importación — con al menos una "activa", va a aparecer el botón "Importar" en la Lista.
        </p>

        <table :if={@plantillas != []} class="min-w-full mb-2">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Nombre</th>
              <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Descripción</th>
              <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Detalles incluidos</th>
              <th class="px-1.5 py-1 text-center font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Estado</th>
              <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Última modificación</th>
              <th class="px-1.5 py-1 border-b border-gray-200"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={p <- @plantillas} class="border-b border-gray-100 hover:bg-gray-50">
              <td class="px-1.5 py-1 text-gray-900 font-semibold">{p.nombre}</td>
              <td class="px-1.5 py-1 text-gray-500">{p.descripcion || "—"}</td>
              <td class="px-1.5 py-1 text-gray-500">
                {(p.definicion["detalles"] || []) |> Enum.count(& &1["activo"]) |> then(&(&1 == 0 && "—" || "#{&1}"))}
              </td>
              <td class="px-1.5 py-1 text-center">
                <span class={[
                  "inline-flex items-center px-1.5 py-0.5 rounded-full font-semibold",
                  p.estado == "activa" && "bg-green-50 text-green-700",
                  p.estado != "activa" && "bg-gray-100 text-gray-500"
                ]}>
                  {if p.estado == "activa", do: "Activa", else: "Borrador"}
                </span>
              </td>
              <td class="px-1.5 py-1 text-gray-500">{Calendar.strftime(p.updated_at || p.inserted_at, "%d/%m/%Y %H:%M")}</td>
              <td class="px-1.5 py-1 whitespace-nowrap text-right">
                <%!-- target="_blank" a propósito: un <a href> normal hace que
                     LiveView detecte "va a navegar" y mate el socket de esta
                     página antes de saber que la respuesta es una descarga de
                     archivo, no una navegación real — bug real reportado
                     ("Activar"/"Subir y validar" quedaban mudos después de
                     descargar, sin ningún error visible). --%>
                <.link href={~p"/sysadmin/importacion/#{p.id}/descargar"} target="_blank" class="text-purple-600 hover:text-purple-800 font-semibold mr-2">Descargar</.link>
                <button type="button" phx-click="editar_plantilla" phx-value-id={p.id} class="text-blue-600 hover:text-blue-800 font-semibold mr-2">Editar</button>
                <button :if={p.estado != "activa"} type="button" phx-click="activar_plantilla" phx-value-id={p.id} class="text-green-600 hover:text-green-800 font-semibold mr-2">Activar</button>
                <button :if={p.estado == "activa"} type="button" phx-click="desactivar_plantilla" phx-value-id={p.id} class="text-gray-500 hover:text-gray-700 font-semibold mr-2">Desactivar</button>
                <button type="button" phx-click="eliminar_plantilla" phx-value-id={p.id} data-confirm="¿Eliminar esta plantilla de importación?" class="text-red-600 hover:text-red-800 font-semibold">Eliminar</button>
              </td>
            </tr>
          </tbody>
        </table>

        <button type="button" phx-click="nueva_plantilla" class="text-purple-700 hover:text-purple-900 font-semibold">+ Nueva plantilla</button>
      </div>
    </div>
    """
  end

  attr :editor, :map, required: true
  attr :campos_disponibles, :list, required: true

  defp editor_plantilla(assigns) do
    campos_meta = Map.new(assigns.campos_disponibles, &{&1.campo, &1})
    incluidos = Enum.filter(assigns.editor["elegidos"], & &1["incluido"])

    assigns = assigns |> assign(:campos_meta, campos_meta) |> assign(:incluidos, incluidos)

    ~H"""
    <div class="border border-gray-200 rounded-lg">
      <div class="px-4 py-2.5 border-b border-gray-100 bg-gray-50 flex items-center justify-between">
        <span class="font-bold text-gray-700 text-sm">{if @editor["id"], do: "Editar plantilla", else: "Nueva plantilla de importación"}</span>
        <button type="button" phx-click="cerrar_editor" class="text-gray-400 hover:text-gray-700">
          <span class="material-symbols-outlined" style="font-size:18px">close</span>
        </button>
      </div>

      <div class="p-4">
        <div :if={@editor["error"]} class="bg-red-50 text-red-700 rounded-lg px-3 py-2 mb-3">{@editor["error"]}</div>

        <div class="flex items-center gap-2 mb-4 text-[11px] font-semibold">
          <span class={["px-2 py-1 rounded", @editor["paso"] == 1 && "bg-purple-600 text-white", @editor["paso"] != 1 && "bg-gray-100 text-gray-500"]}>1. Campos</span>
          <span class="text-gray-300">→</span>
          <span class={["px-2 py-1 rounded", @editor["paso"] == 2 && "bg-purple-600 text-white", @editor["paso"] != 2 && "bg-gray-100 text-gray-500"]}>2. Detalles</span>
          <span class="text-gray-300">→</span>
          <span class={["px-2 py-1 rounded", @editor["paso"] == 3 && "bg-purple-600 text-white", @editor["paso"] != 3 && "bg-gray-100 text-gray-500"]}>3. Vista previa y guardar</span>
        </div>

        <form phx-change="wizard_cambiar" phx-submit="guardar_plantilla">
          <%= if @editor["paso"] == 1 do %>
            <div class="flex items-center gap-2 mb-1 text-[11px]">
              <button type="button" phx-click="wizard_marcar_todos" phx-value-scope="encabezado" phx-value-valor="true" class="text-purple-600 hover:text-purple-800 font-semibold">Marcar todos</button>
              <span class="text-gray-300">·</span>
              <button type="button" phx-click="wizard_marcar_todos" phx-value-scope="encabezado" phx-value-valor="false" class="text-gray-500 hover:text-gray-700 font-semibold">Desmarcar todos</button>
            </div>
            <table class="min-w-full mb-3">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-1.5 py-1 border-b border-gray-200"></th>
                  <th class="px-1.5 py-1 text-center font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Incluir</th>
                  <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Campo</th>
                  <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Tipo</th>
                  <th class="px-1.5 py-1 text-center font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Obligatorio</th>
                  <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Identificar por (si es referencia)</th>
                </tr>
              </thead>
              <tbody id="wizard-campos-incluidos-ordenable" phx-hook="ListaOrdenable" data-grupo="wizard-importacion-campos">
                <tr :for={item <- @incluidos} id={"wizard-campo-#{item["campo"]}"} data-id={item["campo"]} class="border-b border-gray-100">
                  <td class="px-1.5 py-1 text-gray-300 jal-manija cursor-grab" title="Arrastrar para reordenar">
                    <span class="material-symbols-outlined" style="font-size: 16px">drag_indicator</span>
                  </td>
                  <.fila_campo item={item} meta={@campos_meta[item["campo"]]} prefix="elegidos" />
                </tr>
                <tr :for={item <- Enum.reject(@editor["elegidos"], & &1["incluido"])} class="border-b border-gray-100 opacity-60">
                  <td></td>
                  <.fila_campo item={item} meta={@campos_meta[item["campo"]]} prefix="elegidos" />
                </tr>
              </tbody>
            </table>

            <div class="flex justify-end">
              <button type="button" phx-click="wizard_ir_paso" phx-value-paso="2" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">
                Siguiente →
              </button>
            </div>
          <% end %>

          <%= if @editor["paso"] == 2 do %>
            <p :if={@editor["detalles"] == []} class="text-gray-400 mb-3">Este catálogo no tiene detalles configurados (maestro-detalle) — no hay nada que activar acá.</p>

            <div :if={@editor["detalles"] != []}>
              <div class="mb-3">
                <label class="block text-gray-500 mb-0.5">Campo identificador del encabezado (vincula las hojas de detalle — ej. Folio)</label>
                <select name="campo_identificador_encabezado" class="border border-gray-300 rounded-lg px-2 py-1.5">
                  <option value="">— Elegir —</option>
                  <option :for={c <- @campos_disponibles} value={c.campo} selected={@editor["campo_identificador_encabezado"] == c.campo}>{c.etiqueta}</option>
                </select>
              </div>

              <div :for={d <- @editor["detalles"]} class="border border-gray-200 rounded-lg p-3 mb-2">
                <label class="flex items-center gap-2 font-semibold text-gray-800 mb-2">
                  <input type="hidden" name={"detalles[#{d["catalogo"]}][activo]"} value="false" />
                  <input type="checkbox" name={"detalles[#{d["catalogo"]}][activo]"} value="true" checked={d["activo"]} class="accent-purple-600" />
                  {d["etiqueta"]}
                </label>

                <div :if={d["activo"]} class="flex items-center gap-2 mb-1 text-[11px]">
                  <button type="button" phx-click="wizard_marcar_todos" phx-value-scope="detalle" phx-value-catalogo={d["catalogo"]} phx-value-valor="true" class="text-purple-600 hover:text-purple-800 font-semibold">Marcar todos</button>
                  <span class="text-gray-300">·</span>
                  <button type="button" phx-click="wizard_marcar_todos" phx-value-scope="detalle" phx-value-catalogo={d["catalogo"]} phx-value-valor="false" class="text-gray-500 hover:text-gray-700 font-semibold">Desmarcar todos</button>
                </div>
                <table :if={d["activo"]} class="min-w-full">
                  <thead class="bg-gray-50">
                    <tr>
                      <th class="px-1.5 py-1 text-center font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Incluir</th>
                      <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Campo</th>
                      <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Tipo</th>
                      <th class="px-1.5 py-1 text-center font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Obligatorio</th>
                      <th class="px-1.5 py-1 text-left font-semibold uppercase tracking-wide text-[11px] text-gray-500 border-b border-gray-200">Identificar por (si es referencia)</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={item <- d["elegidos"]} class="border-b border-gray-100">
                      <.fila_campo item={item} meta={campo_meta_de(d["catalogo"], item["campo"])} prefix={"detalles[#{d["catalogo"]}][elegidos]"} />
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>

            <div class="flex justify-between mt-3">
              <button type="button" phx-click="wizard_ir_paso" phx-value-paso="1" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
                ← Volver
              </button>
              <button type="button" phx-click="wizard_ir_paso" phx-value-paso="3" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">
                Siguiente →
              </button>
            </div>
          <% end %>

          <%= if @editor["paso"] == 3 do %>
            <div class="grid grid-cols-2 gap-3 mb-3">
              <div>
                <label class="block text-gray-500 mb-0.5">Nombre de la plantilla</label>
                <input type="text" name="nombre" value={@editor["nombre"]} maxlength="100" required
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5" />
              </div>
              <div>
                <label class="block text-gray-500 mb-0.5">Descripción (opcional)</label>
                <input type="text" name="descripcion" value={@editor["descripcion"]} maxlength="255"
                  class="w-full border border-gray-300 rounded-lg px-2 py-1.5" />
              </div>
            </div>

            <p class="text-gray-500 mb-1">Vista previa del Excel — hoja de encabezado:</p>
            <.tabla_vista_previa campos={@incluidos} campos_meta={@campos_meta} />

            <%= for d <- Enum.filter(@editor["detalles"], & &1["activo"]) do %>
              <p class="text-gray-500 mb-1 mt-3">Hoja "{d["etiqueta"]}":</p>
              <.tabla_vista_previa campos={Enum.filter(d["elegidos"], & &1["incluido"])} campos_meta={Map.new(MetadataApp.MetaImportacionDatos.campos_disponibles(d["catalogo"]), &{&1.campo, &1})} />
            <% end %>

            <div class="flex justify-between mt-3">
              <button type="button" phx-click="wizard_ir_paso" phx-value-paso="2" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
                ← Volver
              </button>
              <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">
                Guardar plantilla
              </button>
            </div>
          <% end %>
        </form>
      </div>
    </div>
    """
  end

  # Metadata de un campo de un catálogo DETALLE (no del encabezado) —
  # usada dentro del :for de "detalles" arriba, donde @campos_meta (el
  # assign de nivel superior) no aplica.
  defp campo_meta_de(catalogo, campo) do
    catalogo |> MetaImportacionDatos.campos_disponibles() |> Enum.find(&(&1.campo == campo))
  end

  attr :campos, :list, required: true
  attr :campos_meta, :map, required: true

  defp tabla_vista_previa(assigns) do
    ~H"""
    <div class="overflow-x-auto border border-gray-200 rounded-lg mb-2">
      <table class="min-w-full">
        <thead class="bg-gray-50">
          <tr>
            <th :for={item <- @campos} class="px-2 py-1.5 text-left font-bold text-gray-800 border-b border-gray-200 whitespace-nowrap">
              {@campos_meta[item["campo"]].etiqueta}{if item["obligatorio"], do: " *"}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td :for={item <- @campos} class="px-2 py-1 text-gray-400 italic whitespace-nowrap">{@campos_meta[item["campo"]].ejemplo}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :meta, :map, required: true
  attr :prefix, :string, required: true

  defp fila_campo(assigns) do
    ~H"""
    <td class="px-1.5 py-1 text-center">
      <input type="hidden" name={"#{@prefix}[#{@item["campo"]}][incluido]"} value="false" />
      <input type="checkbox" name={"#{@prefix}[#{@item["campo"]}][incluido]"} value="true" checked={@item["incluido"]} class="accent-purple-600" />
    </td>
    <td class="px-1.5 py-1 text-gray-900">{@meta.etiqueta}</td>
    <td class="px-1.5 py-1 text-gray-500 font-mono">{@meta.tipo}</td>
    <td class="px-1.5 py-1 text-center">
      <input type="hidden" name={"#{@prefix}[#{@item["campo"]}][obligatorio]"} value="false" />
      <input type="checkbox" name={"#{@prefix}[#{@item["campo"]}][obligatorio]"} value="true" checked={@item["obligatorio"]} disabled={!@item["incluido"]} class="accent-purple-600" />
    </td>
    <td class="px-1.5 py-1">
      <select :if={@meta.tipo == "referencia" and @item["incluido"]} name={"#{@prefix}[#{@item["campo"]}][campo_identificador]"}
        class="border border-gray-300 rounded-lg px-1.5 py-1">
        <option value="">— Elegir —</option>
        <option :for={c <- MetadataApp.MetaImportacionDatos.campos_disponibles(@meta.catalogo_destino)} value={c.campo} selected={@item["campo_identificador"] == c.campo}>
          {c.etiqueta}
        </option>
      </select>
      <span :if={@meta.tipo != "referencia"} class="text-gray-300">—</span>
    </td>
    """
  end
end
