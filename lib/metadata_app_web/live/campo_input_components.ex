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
  etiqueta al lado — evita mostrarla duplicada.
  """
  use Phoenix.Component

  attr :columna, :map, required: true
  attr :valor, :string, default: nil
  attr :mostrar_etiqueta, :boolean, default: true

  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "boolean"}}} = assigns) do
    ~H"""
    <label class="flex items-center gap-1.5 mb-0.5">
      <input type="hidden" name={"campos[#{@columna.schema_context_field}]"} value="false" />
      <input type="checkbox" name={"campos[#{@columna.schema_context_field}]"} value="true" checked={@valor == "true"} class="accent-purple-600" />
      <span :if={@mostrar_etiqueta}>{@columna.schema_context_properties["etiqueta"]}</span>
    </label>
    """
  end

  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "enum"}}} = assigns) do
    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-0.5">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <select name={"campos[#{@columna.schema_context_field}]"} required
        class="w-full border border-gray-300 rounded text-gray-900 px-2 py-1.5">
        <option :for={v <- @columna.schema_context_properties["valores"]} value={v} selected={v == @valor}>{v}</option>
      </select>
    </div>
    """
  end

  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => tipo}}} = assigns)
      when tipo in ["integer", "decimal"] do
    assigns = assign(assigns, :step, if(tipo == "decimal", do: "any"))

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-0.5">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <input type="number" step={@step} name={"campos[#{@columna.schema_context_field}]"} value={@valor} required
        class="w-full border border-gray-300 rounded text-gray-900 px-2 py-1.5" />
    </div>
    """
  end

  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "date"}}} = assigns) do
    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-0.5">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <input type="date" name={"campos[#{@columna.schema_context_field}]"} value={@valor} required
        class="w-full border border-gray-300 rounded text-gray-900 px-2 py-1.5" />
    </div>
    """
  end

  # Default (string, referencia sin picker todavía — ver
  # project_frontend_referencia_ux, responsabilidad de Frontend a futuro).
  def campo_input(assigns) do
    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-0.5">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <input type="text" name={"campos[#{@columna.schema_context_field}]"} value={@valor} required
        maxlength={@columna.schema_context_properties["longitud"]}
        class="w-full border border-gray-300 rounded text-gray-900 px-2 py-1.5" />
    </div>
    """
  end
end
