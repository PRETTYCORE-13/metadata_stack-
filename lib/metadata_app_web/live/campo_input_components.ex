defmodule MetadataAppWeb.CampoInputComponents do
  @moduledoc """
  Input de un campo según su tipo (`schema_context_properties["tipo"]`) —
  extraído de `CatalogoLive` (donde vivía como `campo_input/1`, para el form
  "+ Agregar renglón") para que `FichaLive` lo reuse tal cual en la edición
  en el lugar de la Ficha 360°, sin duplicar el dispatch por tipo.

  `valor` (opcional, string) precarga el input — nil de default, que es
  exactamente lo que ya quería "+ Agregar renglón" (arranca vacío, no hay
  registro previo que mostrar). `mostrar_etiqueta` (default true) se apaga
  desde `FichaLive.campo_row/1`, que ya tiene su propia columna de
  etiqueta al lado — evita mostrarla duplicada. `name` (opcional) reemplaza
  el `"campos[campo]"` de siempre — lo usa la tabla de renglones de
  `FichaLive` para nombrar cada celda como `"renglones[IDX][campo]"`, así
  el `phx-change` de la tabla llega con el índice de fila incluido.
  `required` (default true) lo apaga la misma tabla: por diseño siempre
  deja una fila en blanco al final para seguir tipeando, y el HTML5
  `required` bloquearía cualquier submit nativo (incluido el Enter
  accidental) mientras esa fila exista a medio llenar.
  """
  use Phoenix.Component

  attr :columna, :map, required: true
  attr :valor, :string, default: nil
  attr :mostrar_etiqueta, :boolean, default: true
  attr :name, :string, default: nil
  attr :required, :boolean, default: true
  attr :opciones, :list, default: []

  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "boolean"}}} = assigns) do
    assigns = assign_name(assigns)

    ~H"""
    <label class="flex items-center gap-1 text-[11px] leading-tight">
      <input type="hidden" name={@name} value="false" />
      <input type="checkbox" name={@name} value="true" checked={@valor == "true"} class="accent-purple-600" />
      <span :if={@mostrar_etiqueta} class="text-gray-500">{@columna.schema_context_properties["etiqueta"]}</span>
    </label>
    """
  end

  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "enum"}}} = assigns) do
    assigns = assign_name(assigns)

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <select name={@name} required={@required}
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight">
        <option :for={v <- @columna.schema_context_properties["valores"]} value={v} selected={v == @valor}>{v}</option>
      </select>
    </div>
    """
  end

  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => tipo}}} = assigns)
      when tipo in ["integer", "decimal"] do
    assigns = assigns |> assign_name() |> assign(:step, if(tipo == "decimal", do: "any"))

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <input type="number" step={@step} name={@name} value={@valor} required={@required}
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight" />
    </div>
    """
  end

  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "date"}}} = assigns) do
    assigns = assign_name(assigns)

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <input type="date" name={@name} value={@valor} required={@required}
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight" />
    </div>
    """
  end

  # Referencia: picker simple (<select>, sin búsqueda — catálogos grandes
  # quedan para una Fase 2, ver docs/roadmap-campos-acompanamiento.md).
  # `@opciones` ([{id, etiqueta}, ...]) la arma el caller vía
  # CatalogoGenerico.opciones_referencia/1 — la etiqueta ya viene resuelta
  # desde "campos_acompanamiento" (o "#<id>" si el catálogo destino no
  # configuró ninguno), así se ve el dato real en vez del id crudo. Mismo
  # criterio que "enum" arriba: sin placeholder en blanco, si @valor no
  # matchea ninguna opción el navegador selecciona la primera.
  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "referencia"}}} = assigns) do
    assigns = assign_name(assigns)

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <select name={@name} required={@required}
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight">
        <option :for={{id, etiqueta} <- @opciones} value={id} selected={to_string(id) == @valor}>{etiqueta}</option>
      </select>
    </div>
    """
  end

  # Default (string).
  def campo_input(assigns) do
    assigns = assign_name(assigns)

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <input type="text" name={@name} value={@valor} required={@required}
        maxlength={@columna.schema_context_properties["longitud"]}
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight" />
    </div>
    """
  end

  defp assign_name(%{name: nil} = assigns), do: assign(assigns, :name, "campos[#{assigns.columna.schema_context_field}]")
  defp assign_name(assigns), do: assigns
end
