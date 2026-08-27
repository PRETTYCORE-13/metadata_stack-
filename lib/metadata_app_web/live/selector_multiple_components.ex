defmodule MetadataAppWeb.SelectorMultipleComponents do
  @moduledoc """
  Lookup de selección múltiple (checkbox a la izquierda de cada opción,
  "Todos"/"Ninguno" arriba) — reemplaza el `<select multiple>` nativo
  para los parámetros "multi" (Get Config admin y la barra de Parámetros
  del reporte, ver moduledoc de `MetadataApp.MetaSchema.Consulta`): un
  `<select multiple>` exige ctrl/cmd+click para elegir más de un valor,
  nada discoverable — acá cada opción es un checkbox real, uno por
  renglón, más un atajo para elegir todos o ninguno de una.

  Popover 100% en HEEx/JS.toggle (mismo patrón que `panel_campos/1` en
  CatalogoLive) -- abrir/cerrar no pega al servidor, solo el estado real
  de los checkboxes (cada uno con su propio `phx-change`, sin form
  ancestro -- ver moduledoc de `panel_get_config/1` en ConsultaEditorLive
  sobre por qué hace falta `form="..."` explícito).

  El LiveView que lo use tiene que implementar 3 `handle_event`:
    - `evento` (change) -- recibe `%{"valores" => %{clave => lista}}`
      (todos los checkboxes con ese `name` comparten el mismo, así que el
      cliente manda SIEMPRE la lista completa de los que están
      tildados, no solo el que se acaba de clickear).
    - `evento_todos` (click) -- recibe `%{"campo" => clave, "valores" => csv}`
      (`csv` = todos los ids de `opciones`, ya armado acá).
    - `evento_ninguno` (click) -- recibe `%{"campo" => clave}`.
  """
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  attr :id, :string, required: true, doc: "id único del popover (ej. \"param-multi-\#{clave}\")"
  attr :form_id, :string, required: true, doc: "id del <form> detached al que se asocian los checkboxes vía form=\"\""
  attr :evento, :string, required: true
  attr :evento_todos, :string, required: true
  attr :evento_ninguno, :string, required: true
  attr :campo_clave, :string, required: true
  attr :opciones, :list, required: true, doc: "[{id, etiqueta}]"
  attr :seleccionados, :list, required: true, doc: "ids seleccionados, como string"

  def selector_multiple(assigns) do
    valores_csv = Enum.map_join(assigns.opciones, ",", fn {id, _etiqueta} -> id end)
    resumen = resumen_seleccion(assigns.seleccionados, assigns.opciones)
    assigns = assigns |> assign(:valores_csv, valores_csv) |> assign(:resumen, resumen)

    ~H"""
    <div class="relative" id={"lookup-#{@id}"}>
      <button type="button" phx-click={JS.toggle(to: "#lookup-popover-#{@id}")}
        class="w-full flex items-center justify-between gap-1 border border-gray-300 rounded-lg text-xs px-2 py-1.5 bg-white text-gray-700 hover:bg-gray-50">
        <span class="truncate">{@resumen}</span>
        <span class="material-symbols-outlined text-gray-400 flex-shrink-0" style="font-size:16px">expand_more</span>
      </button>

      <div id={"lookup-popover-#{@id}"} class="hidden absolute z-50 mt-1 w-64 max-h-72 flex flex-col bg-white border border-gray-200 rounded-lg shadow-xl" phx-click-away={JS.hide()}>
        <div class="flex items-center gap-2 px-3 py-2 border-b border-gray-200 flex-shrink-0">
          <button type="button" phx-click={@evento_todos} phx-value-campo={@campo_clave} phx-value-valores={@valores_csv}
            class="text-[11px] font-semibold text-purple-700 hover:underline">
            Todos
          </button>
          <span class="text-gray-300">·</span>
          <button type="button" phx-click={@evento_ninguno} phx-value-campo={@campo_clave}
            class="text-[11px] font-semibold text-purple-700 hover:underline">
            Ninguno
          </button>
        </div>

        <div class="overflow-y-auto py-1 flex-1">
          <label :for={{id, etiqueta} <- @opciones} class="flex items-center gap-2 px-3 py-1.5 text-xs text-gray-700 hover:bg-gray-50 cursor-pointer">
            <input type="checkbox" phx-change={@evento} form={@form_id} name={"valores[#{@campo_clave}][]"} value={id}
              checked={to_string(id) in @seleccionados} class="accent-purple-600 flex-shrink-0" />
            <span class="truncate">{etiqueta}</span>
          </label>
          <p :if={@opciones == []} class="px-3 py-2 text-xs text-gray-400">Sin opciones.</p>
        </div>
      </div>
    </div>
    """
  end

  defp resumen_seleccion([], _opciones), do: "Ninguno"
  defp resumen_seleccion(seleccionados, opciones) when length(seleccionados) >= length(opciones) and opciones != [], do: "Todos (#{length(opciones)})"
  defp resumen_seleccion(seleccionados, _opciones), do: "#{length(seleccionados)} seleccionados"
end
