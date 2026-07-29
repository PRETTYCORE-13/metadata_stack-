defmodule MetadataAppWeb.GridEditableComponents do
  @moduledoc """
  Grid Editable Empresarial — captura tipo Excel de renglones, reusable para
  cualquier catálogo maestro-detalle (Ficha 360° hoy; cualquier otra pantalla
  a futuro, ver docs/catalogo-maestro-detalle-requerimientos.md Fase 6/Fase 1
  del Grid Editable). Reemplaza al viejo `renglones_grid/1` de `FichaLive`.

  Todo el estado interactivo (teclado, pegado, validación en vivo, filas en
  staging) vive en el hook JS `GridEditable`
  (assets/js/hooks/grid_editable.js) — este componente solo arma el shell
  inicial: metadata de columnas/filas ya persistidas como JSON en `data-*`.
  El elemento raíz lleva `phx-update="ignore"`: LiveView nunca vuelve a tocar
  ese `<tbody>` después del primer montaje, el hook es el único dueño de ese
  DOM. Cualquier actualización posterior (después de "Guardar", o de una
  transición de un renglón puntual) viaja por `push_event("grid_recargar",
  ...)` desde el LiveView que lo usa — nunca por un re-render normal, porque
  `phx-update="ignore"` lo ignoraría igual.
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
      |> assign(:total_columnas, length(assigns.columnas) + 3)

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
              <th class="px-2 py-1.5 text-left text-gray-500 w-8">#</th>
              <th class="px-1 py-1.5 w-4"></th>
              <th :for={col <- @columnas} class="px-2 py-1.5 text-left text-gray-500">
                {col.schema_context_properties["etiqueta"]}
              </th>
              <th class="px-2 py-1.5 text-right text-gray-500">Acciones</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td colspan={@total_columnas} class="px-3 py-4 text-center text-gray-400">Cargando…</td>
            </tr>
          </tbody>
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
      valores: props["valores"]
    }
  end

  defp fila_meta(r, columnas, estados_por_id) do
    valores =
      Map.new(columnas, fn col ->
        {col.schema_context_field, to_string(Map.get(r, String.to_existing_atom(col.schema_context_field)))}
      end)

    %{renglon_id: r.renglon_id, estado: Map.get(estados_por_id, r.estado_id) || "—", values: valores}
  end
end
