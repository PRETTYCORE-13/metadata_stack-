defmodule MetadataAppWeb.GridEditableComponents do
  @moduledoc """
  Grid Editable Empresarial — vista de renglones de un catálogo
  maestro-detalle, reusable para cualquiera (Ficha 360° hoy; cualquier otra
  pantalla a futuro, ver docs/catalogo-maestro-detalle-requerimientos.md
  Fase 6/Fase 1 del Grid Editable). Reemplaza al viejo `renglones_grid/1` de
  `FichaLive`.

  La tabla en sí es de SOLO LECTURA — un clic en una fila la selecciona
  para editarla en `FichaLive.formulario_renglon/1` (al lado), que es donde
  vive toda la captura/edición real. El estado (selección, filas en
  staging) vive en el hook JS `GridEditable`
  (assets/js/hooks/grid_editable.js) — este componente solo arma el shell
  inicial: metadata de columnas/filas ya persistidas como JSON en `data-*`.
  El elemento raíz lleva `phx-update="ignore"`: LiveView nunca vuelve a tocar
  ese `<tbody>` después del primer montaje, el hook es el único dueño de ese
  DOM. Cualquier actualización posterior (después de "Guardar", de una
  transición de un renglón puntual, o de una edición desde el formulario)
  viaja por `push_event(...)` desde el LiveView que lo usa — nunca por un
  re-render normal, porque `phx-update="ignore"` lo ignoraría igual.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :catalogo, :string, required: true
  attr :columnas, :list, required: true
  attr :filas_existentes, :list, default: []
  attr :transiciones_disponibles, :list, default: []
  attr :estados_por_id, :map, default: %{}

  def grid(assigns) do
    assigns =
      assigns
      |> assign(:columnas_json, Jason.encode!(columnas_para_js(assigns.columnas)))
      |> assign(:filas_json, Jason.encode!(filas_para_js(assigns.filas_existentes, assigns.columnas, assigns.estados_por_id)))
      |> assign(:transiciones_json, Jason.encode!(Enum.map(assigns.transiciones_disponibles, &Map.take(&1, [:accion, :etiqueta]))))
      |> assign(:total_columnas, length(assigns.columnas) + 2)

    ~H"""
    <div id={@id} phx-hook="GridEditable" phx-update="ignore"
      data-catalogo={@catalogo} data-columnas={@columnas_json} data-filas={@filas_json} data-transiciones={@transiciones_json}
      class="overflow-x-auto">
      <!-- .ge-scroll: el hook JS le pone altura fija + overflow-y solo
           cuando hay filas de sobra como para virtualizar (Fase 2) — con
           pocas filas queda sin estilo propio, la tabla crece normal. -->
      <div class="ge-scroll">
        <table class="min-w-full divide-y divide-gray-100 text-xs">
          <thead class="bg-gray-50 sticky top-0 z-10">
            <tr>
              <th class="px-1.5 py-1 text-left text-gray-500 w-8">#</th>
              <th class="px-1 py-1 w-4"></th>
              <th :for={col <- @columnas} class="px-1.5 py-1 text-left text-gray-500">
                {col.schema_context_properties["etiqueta"]}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td colspan={@total_columnas} class="px-3 py-4 text-center text-gray-400">Cargando…</td>
            </tr>
          </tbody>
          <!-- Fila de resumen — placeholder vacío y oculto por default, el
               hook JS la arma/muestra según la metadata de cada columna. -->
          <tfoot class="bg-gray-50 sticky bottom-0 z-10 border-t border-gray-200">
            <tr class="ge-resumen-fila" data-resumen-pos="abajo" style="display:none"></tr>
          </tfoot>
        </table>
      </div>
    </div>
    """
  end

  @doc "Metadata de columnas en la forma que espera el hook GridEditable — pública para reusar en push_event (ver FichaLive)."
  def columnas_para_js(columnas), do: Enum.map(columnas, &columna_meta/1)

  @doc "Filas ya persistidas en la forma que espera el hook GridEditable (data-filas al montar, o push_event(\"grid_recargar\", ...) después) — pública para reusar en FichaLive tras una transición de renglón."
  def filas_para_js(filas, columnas, estados_por_id), do: Enum.map(filas, &fila_meta(&1, columnas, estados_por_id))

  defp columna_meta(col) do
    props = col.schema_context_properties

    %{
      campo: col.schema_context_field,
      etiqueta: props["etiqueta"],
      tipo: props["tipo"],
      opcional: props["opcional"] == true,
      longitud: props["longitud"],
      valores: props["valores"],
      opciones: opciones_columna(col),
      resumen: resumen_estandar(props["tipo"])
    }
  end

  @doc """
  Fila de resumen (pie fijo de la grilla, ver `grid/1` + hook `GridEditable`)
  — estándar fijo para TODAS las grillas de renglones, sin configuración
  por catálogo: toda columna numérica suma por default; el resto no
  muestra nada por default, pero sí admite "Recuento" (cuántos renglones
  tienen algo cargado ahí) con clic derecho — sumar/promediar/etc no
  tiene sentido en una columna no numérica, así que esas dos son las
  únicas opciones que el hook JS ofrece ahí (ver TIPOS_NUMERICOS en
  assets/js/hooks/grid_editable.js). El usuario final elige la operación
  con clic derecho, solo en memoria, nunca se guarda — no hay nada que
  configurar de antemano.
  """
  def resumen_estandar(tipo) when tipo in ["integer", "decimal"],
    do: %{activo: true, operacion: "suma", formato: "numero", decimales: 2, editable_runtime: true}

  def resumen_estandar(_tipo), do: %{activo: false, operacion: "ninguno", editable_runtime: true}

  # Igual que el picker de referencia del formulario de al lado
  # (CampoInputComponents.campo_input/1) — el hook JS pinta un <select>
  # con esto en vez de la caja de texto libre de siempre para una columna
  # tipo "referencia". Tupla -> mapa porque Jason no sabe serializar
  # tuplas de Elixir.
  #
  # `col.opciones` ya viene precalculado por el caller (ver
  # FichaLive.cargar_catalogos_detalle/1) como tuplas {id, etiqueta} — el
  # mismo formato que espera CampoInputComponents.campo_input/1 del lado
  # de FichaLive. Acá igual hay que pasarlas a mapa (Jason no serializa
  # tuplas). Este componente corre en cada render (el <tbody
  # phx-update="ignore"> no evita que el server vuelva a armar los
  # assigns), así que ir a buscar hasta 500 filas del catálogo
  # referenciado acá adentro sería repetirlo por cada evento de la Ficha
  # 360°. Fallback a la consulta en vivo solo por si algún caller nuevo
  # todavía no manda columnas con :opciones ya resuelto.
  defp opciones_columna(%{opciones: opciones}),
    do: Enum.map(opciones, fn {id, etiqueta} -> %{id: id, etiqueta: etiqueta} end)

  defp opciones_columna(%{schema_context_properties: %{"tipo" => "referencia"} = props}) do
    props
    |> MetadataApp.BusinessProcessBuilder.CatalogoGenerico.opciones_referencia()
    |> Enum.map(fn {id, etiqueta} -> %{id: id, etiqueta: etiqueta} end)
  end

  defp opciones_columna(_col), do: []

  defp fila_meta(r, columnas, estados_por_id) do
    valores =
      Map.new(columnas, fn col ->
        {col.schema_context_field, to_string(Map.get(r, String.to_existing_atom(col.schema_context_field)))}
      end)

    %{renglon_id: r.renglon_id, estado: Map.get(estados_por_id, r.estado_id) || "—", values: valores}
  end
end
