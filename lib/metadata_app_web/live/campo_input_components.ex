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
  attr :mensaje_dependencia, :string, default: nil

  @modos_posicionales ~w(telefono cp rfc curp fecha personalizada)

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

  # "valores" tiene dos formas posibles: Simple (lista de string, el texto
  # ES el valor guardado) o Mapeado (lista de %{"valor"=>, "descripcion"=>},
  # ver Diseñador de campos → Lista → "Guardar un código distinto al
  # texto mostrado") — opciones_enum/1 normaliza las dos a {valor,
  # etiqueta} para no duplicar el <option> por forma.
  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "enum"}}} = assigns) do
    assigns = assign_name(assigns)

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <select name={@name} required={@required} disabled={@disabled}
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed">
        <option :for={{v, etiqueta} <- opciones_enum(@columna.schema_context_properties["valores"])} value={v} selected={v == @valor}>{etiqueta}</option>
      </select>
    </div>
    """
  end

  # "Formato de captura" numérico/moneda (opcional, ver
  # MetaSchemaContext.validar_formato_captura/2): el input real SIGUE
  # siendo un <input type="number"> nativo (el navegador ya bloquea
  # letras solo) — nunca se reformatea en caliente con comas/símbolo,
  # porque insertar separadores mientras el cursor está a mitad de tipeo
  # lo hace saltar de lugar. En cambio, un <span> hermano de solo lectura
  # (hook FormatoNumericoField) muestra "$1,234.00" en vivo al lado, sin
  # tocar el valor que en definitiva viaja en el submit.
  def campo_input(
        %{
          columna: %{
            schema_context_properties: %{
              "tipo" => tipo,
              "formato_captura" => %{"habilitada" => true, "modo" => modo} = formato
            }
          }
        } = assigns
      )
      when tipo in ["integer", "decimal"] and modo in ["numero", "moneda"] do
    assigns = assign_name(assigns)

    assigns =
      assigns
      |> assign(:step, paso_numerico(formato))
      |> assign(:formato, formato)
      |> assign(:dom_id, assigns.id || "campo-#{String.replace(assigns.name, ~r/[\[\]]/, "-")}")

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <div class="flex items-center gap-1.5">
        <input type="number" step={@step} min={if @formato["permitir_negativos"] != true, do: "0"}
          name={@name} value={@valor} required={@required} disabled={@disabled}
          id={@dom_id} phx-hook="FormatoNumericoField"
          data-decimales={@formato["decimales"] || 0}
          data-separador-miles={to_string(@formato["separador_miles"] == true)}
          data-simbolo={@formato["modo"] == "moneda" && @formato["simbolo"]}
          data-simbolo-posicion={@formato["simbolo_posicion"] || "prefijo"}
          data-preview-de={"#{@dom_id}-preview"}
          class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed" />
        <span id={"#{@dom_id}-preview"} class="text-gray-400 text-[11px] whitespace-nowrap"></span>
      </div>
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
        placeholder={@columna.schema_context_properties["placeholder"]}
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed" />
    </div>
    """
  end

  # AbrirCalendario (mismo hook que ya usa "Filtros por default" en
  # BcMotorLive): sin esto, un clic en cualquier parte del input que no
  # sea el iconito diminuto del calendario nativo deja al usuario
  # tipeando dígito por dígito sin ningún selector visual — showPicker()
  # fuerza el calendario con cualquier clic/foco en el campo.
  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "date"}}} = assigns) do
    assigns = assign_name(assigns)
    assigns = assign(assigns, :dom_id, assigns.id || "campo-#{String.replace(assigns.name, ~r/[\[\]]/, "-")}")

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <input type="date" name={@name} value={@valor} required={@required} disabled={@disabled}
        id={@dom_id} phx-hook="AbrirCalendario"
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed" />
    </div>
    """
  end

  # AbrirCalendario también sirve acá tal cual — showPicker() es genérico
  # para date/time/datetime-local/month/week (ver comentario en la
  # cláusula "date" arriba).
  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "hora"}}} = assigns) do
    assigns = assign_name(assigns)
    assigns = assign(assigns, :dom_id, assigns.id || "campo-#{String.replace(assigns.name, ~r/[\[\]]/, "-")}")

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <input type="time" name={@name} value={@valor} required={@required} disabled={@disabled}
        id={@dom_id} phx-hook="AbrirCalendario"
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed" />
    </div>
    """
  end

  # "Texto largo" (memo/comentarios) — a diferencia del texto corto no
  # tiene `longitud` (columna :text sin límite, ver
  # CatalogoGenerador.columna_migracion/3) ni `formato_captura` (es para
  # texto libre, no un dato con patrón).
  def campo_input(%{columna: %{schema_context_properties: %{"tipo" => "texto_largo"}}} = assigns) do
    assigns = assign_name(assigns)

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <textarea name={@name} required={@required} disabled={@disabled} rows="3"
        placeholder={@columna.schema_context_properties["placeholder"]}
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-1 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed">{@valor}</textarea>
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
      |> assign(:placeholder, (assigns.disabled && assigns.mensaje_dependencia) || "Escribí o F2 para buscar…")

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <div id={@dom_id} phx-hook="ReferenciaField" data-opciones={@opciones_json}
        data-disabled={to_string(@disabled)} data-mensaje={@mensaje_dependencia} class="relative">
        <input type="hidden" name={@name} value={@valor} disabled={@disabled} data-campo-hidden />
        <input type="text" autocomplete="off" value={@etiqueta_actual} required={@required} disabled={@disabled} data-campo-texto
          placeholder={@placeholder}
          class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed" />
        <ul data-campo-lista role="listbox"
          class="hidden absolute left-0 right-0 z-20 mt-0.5 max-h-40 overflow-auto rounded border border-gray-200 bg-white shadow-lg"></ul>
      </div>
    </div>
    """
  end

  # "Formato de captura" posicional (Teléfono/CP/RFC/Fecha libre/
  # Personalizada, ver MetaSchemaContext.validar_formato_captura/2): el
  # hook FormatoCapturaField reformatea `el.value` en cada tecla cuando
  # `estricto` está activo (inserta los literales del patrón, descarta
  # caracteres que no calzan con la clase A/9/*) — el `<input>` sigue
  # siendo el mismo que se somete, sin par hidden/visible como
  # ReferenciaField (acá no hay id vs. etiqueta, el valor tipeado ES el
  # valor real). Modo "fecha" suma un selector de calendario nativo al
  # lado (mismo hook AbrirCalendario que ya usa "Filtros por default" en
  # BcMotorLive) — oculto por accesibilidad (sr-only) detrás de su
  # <label>, elegir una fecha ahí escribe el valor YA formateado en el
  # input de texto en vez de reemplazarlo por un input de fecha nativo
  # (que perdería la posibilidad de seguir tipeando el patrón a mano).
  def campo_input(
        %{
          columna: %{
            schema_context_properties: %{
              "tipo" => "string",
              "formato_captura" => %{"habilitada" => true, "modo" => modo} = formato
            }
          }
        } = assigns
      )
      when modo in @modos_posicionales do
    assigns = assign_name(assigns)

    assigns =
      assigns
      |> assign(:formato, formato)
      |> assign(:dom_id, assigns.id || "campo-#{String.replace(assigns.name, ~r/[\[\]]/, "-")}")

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <div class="flex items-center gap-1">
        <input type="text" name={@name} value={@valor} required={@required} disabled={@disabled}
          maxlength={@columna.schema_context_properties["longitud"]}
          id={@dom_id} phx-hook="FormatoCapturaField"
          data-patron={@formato["patron"]}
          data-guardar-formato={to_string(@formato["guardar_formato"] != false)}
          data-estricto={to_string(@formato["estricto"] != false)}
          class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed" />
        <div :if={@formato["modo"] == "fecha" and !@disabled} class="relative flex-none">
          <label for={"#{@dom_id}-calendario"} class="material-symbols-outlined text-gray-400 hover:text-purple-600 cursor-pointer" style="font-size:18px">calendar_month</label>
          <input type="date" id={"#{@dom_id}-calendario"} phx-hook="AbrirCalendario" data-destino={@dom_id} tabindex="-1" class="sr-only" />
        </div>
      </div>
    </div>
    """
  end

  # "Formato de captura" numérico/moneda en un campo tipo "string" (a
  # diferencia de la cláusula "integer"/"decimal" de arriba, acá la
  # columna es texto de verdad — no hay un <input type="number"> nativo
  # que lo proteja solo, así que FormatoNumericoField también filtra los
  # caracteres inválidos al tipear). `guardar_formato` decide si, al
  # perder foco, el valor tipeado se reemplaza por su versión formateada
  # ("$1,234.50") o se deja como dígitos crudos — igual que en el modo
  # posicional de arriba.
  def campo_input(
        %{
          columna: %{
            schema_context_properties: %{
              "tipo" => "string",
              "formato_captura" => %{"habilitada" => true, "modo" => modo} = formato
            }
          }
        } = assigns
      )
      when modo in ["numero", "moneda"] do
    assigns = assign_name(assigns)

    assigns =
      assigns
      |> assign(:formato, formato)
      |> assign(:dom_id, assigns.id || "campo-#{String.replace(assigns.name, ~r/[\[\]]/, "-")}")

    ~H"""
    <div>
      <label :if={@mostrar_etiqueta} class="block text-gray-500 mb-px text-[11px] leading-tight">{@columna.schema_context_properties["etiqueta"]} <span class="text-red-500">*</span></label>
      <div class="flex items-center gap-1.5">
        <input type="text" inputmode="decimal" name={@name} value={@valor} required={@required} disabled={@disabled}
          id={@dom_id} phx-hook="FormatoNumericoField"
          data-decimales={@formato["decimales"] || 0}
          data-separador-miles={to_string(@formato["separador_miles"] == true)}
          data-simbolo={@formato["modo"] == "moneda" && @formato["simbolo"]}
          data-simbolo-posicion={@formato["simbolo_posicion"] || "prefijo"}
          data-permitir-negativos={to_string(@formato["permitir_negativos"] == true)}
          data-guardar-formato={to_string(@formato["guardar_formato"] == true)}
          data-preview-de={"#{@dom_id}-preview"}
          class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed" />
        <span id={"#{@dom_id}-preview"} class="text-gray-400 text-[11px] whitespace-nowrap"></span>
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
        placeholder={@columna.schema_context_properties["placeholder"]}
        class="w-full border border-gray-300 rounded text-gray-900 px-1.5 py-0.5 text-xs leading-tight disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed" />
    </div>
    """
  end

  defp assign_name(%{name: nil} = assigns), do: assign(assigns, :name, "campos[#{assigns.columna.schema_context_field}]")
  defp assign_name(assigns), do: assigns

  defp paso_numerico(%{"decimales" => decimales}) when is_integer(decimales) and decimales > 0,
    do: "0." <> String.duplicate("0", decimales - 1) <> "1"

  defp paso_numerico(_formato), do: "1"

  defp etiqueta_para_valor(opciones, valor) do
    case Enum.find(opciones, fn {id, _etiqueta} -> to_string(id) == valor end) do
      {_id, etiqueta} -> etiqueta
      nil -> ""
    end
  end

  @doc "Normaliza `schema_context_properties[\"valores\"]` de un campo enum a `[{valor, etiqueta}, ...]` — acepta tanto strings sueltos como `%{\"valor\" => , \"descripcion\" => }`."
  def opciones_enum(valores) do
    Enum.map(valores || [], fn
      %{"valor" => v, "descripcion" => d} -> {v, d}
      v when is_binary(v) -> {v, v}
    end)
  end
end
