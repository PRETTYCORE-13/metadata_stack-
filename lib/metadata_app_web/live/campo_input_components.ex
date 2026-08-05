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
  attr :id, :string, default: nil
  attr :disabled, :boolean, default: false

  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "boolean"}}} = assigns) do
    assigns = assign_name(assigns)

    ~H"""
    <label class="flex items-center gap-1 text-[11px] leading-tight">
      <input type="hidden" name={@name} value="false" />
      <input type="checkbox" name={@name} value="true" checked={@valor == "true"} disabled={@disabled}
        class="accent-purple-600 disabled:opacity-50 disabled:cursor-not-allowed" />
      <span :if={@mostrar_etiqueta} class="text-gray-500">{@columna.schema_context_properties["etiqueta"]}</span>
    </label>
    """
  end

  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "enum"}}} = assigns) do
    assigns = assign_name(assigns)

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <select name={@name} required={@required} disabled={@disabled}
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed">
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
      <input type="number" step={@step} name={@name} value={@valor} required={@required} disabled={@disabled}
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed" />
    </div>
    """
  end

  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "date"}}} = assigns) do
    assigns = assign_name(assigns)

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <input type="date" name={@name} value={@valor} required={@required} disabled={@disabled}
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed" />
    </div>
    """
  end

  # Referencia: combobox con filtro LOCAL sobre `@opciones` (sin ida y
  # vuelta al servidor — el hook ReferenciaField filtra en el cliente),
  # abierto con F2 o al tipear. `@opciones` ([{id, etiqueta}, ...]) la arma
  # el caller vía CatalogoGenerico.opciones_referencia/1 — la etiqueta ya
  # viene resuelta desde "campos_acompanamiento" (o "#<id>" si el catálogo
  # destino no configuró ninguno), así se ve el dato real en vez del id
  # crudo. El input de texto visible es el que lleva `required` (un
  # `type="hidden"` queda afuera de la validación nativa del navegador por
  # spec) — así `form.checkValidity()` en RenglonForm bloquea confirmar la
  # línea si no hay ninguna referencia elegida.
  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "referencia"}}} = assigns) do
    assigns = assign_name(assigns)

    assigns =
      assigns
      |> assign(:dom_id, assigns.id || "campo-#{String.replace(assigns.name, ~r/[\[\]]/, "-")}")
      |> assign(:opciones_json, Jason.encode!(Enum.map(assigns.opciones, fn {id, etiqueta} -> %{id: to_string(id), etiqueta: etiqueta} end)))
      |> assign(:etiqueta_actual, etiqueta_para_valor(assigns.opciones, assigns.valor))

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <div id={@dom_id} phx-hook="ReferenciaField" data-opciones={@opciones_json} class="relative">
        <input type="hidden" name={@name} value={@valor} disabled={@disabled} data-campo-hidden />
        <input type="text" autocomplete="off" value={@etiqueta_actual} required={@required} disabled={@disabled} data-campo-texto
          placeholder="Escribí o F2 para buscar…"
          class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed" />
        <ul data-campo-lista role="listbox"
          class="hidden absolute left-0 right-0 z-20 mt-0.5 max-h-40 overflow-auto rounded border border-gray-200 bg-white shadow-lg"></ul>
      </div>
    </div>
    """
  end

  # Default (string).
  def campo_input(assigns) do
    assigns = assign_name(assigns)

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <input type="text" name={@name} value={@valor} required={@required} disabled={@disabled}
        maxlength={@columna.schema_context_properties["longitud"]}
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed" />
    </div>
    """
  end

  defp assign_name(%{name: nil} = assigns), do: assign(assigns, :name, "campos[#{assigns.columna.schema_context_field}]")
  defp assign_name(assigns), do: assigns

  defp etiqueta_para_valor(opciones, valor) do
    case Enum.find(opciones, fn {id, _etiqueta} -> to_string(id) == valor end) do
      {_id, etiqueta} -> etiqueta
      nil -> ""
    end
  end
end
