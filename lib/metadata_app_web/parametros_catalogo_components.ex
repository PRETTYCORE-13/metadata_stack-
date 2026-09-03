defmodule MetadataAppWeb.ParametrosCatalogoComponents do
  @moduledoc """
  SPEC-SYS-0209202601, Grupo C — celdas de Parámetro/Tipo/Acotado/Default/
  Totales de la grilla "Columnas del GET", movidas de
  `consulta_editor_live.ex` (donde nacieron) para que `bc_motor_live.ex`
  las use tal cual, sin copiar/pegar.

  A diferencia del original, cada componente que emite un `<input>`/
  `<select>` recibe `form_id` como attr en vez de tener
  `form="form-guardar-columnas"` escrito a mano -- ese id era literal de
  `consulta_editor_live.ex`, un componente de verdad compartido no puede
  asumir el id del form de quien lo usa.

  Los NOMBRES DE EVENTO (`cambiar_es_parametro`, `cambiar_tipo_filtro`,
  `cambiar_acotado`, `cambiar_origen`, `cambiar_defaults_valor`,
  `cambiar_defaults_valor_hasta`, `cambiar_defaults_valores`,
  `marcar_defaults_todos`, `limpiar_defaults_valores`,
  `cambiar_catalogo_referenciado`, `cambiar_minmax_recomendado`,
  `cambiar_total_pagina`, `cambiar_total_general`, `cambiar_mascara`) SÍ
  quedan fijos -- cada LiveView que use este módulo tiene que implementar
  un `handle_event/3` con ese nombre exacto (mismo criterio que ya
  documentaba `toggle_es_parametro/1`).
  """
  use Phoenix.Component

  import MetadataAppWeb.SelectorMultipleComponents, only: [selector_multiple: 1]

  alias MetadataApp.ParametrosCatalogo
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico

  @doc "Identificador de campo para atributos de HTML (id/name/phx-value) -- NO es `ParametrosCatalogo.clave_campo/1` (ese es un átomo interno para mapas de resultado, este es un string para el DOM/formulario)."
  def identificador(campo), do: "#{campo["catalogo"]}::#{campo["campo"]}"

  # --- 4 celdas de Parámetro (Tipo/Es acotado/Parámetro/Defaults), una
  # por fila, dispatched por tipo. Un campo NO visible o de tipo no
  # elegible (boolean/enum/nil) cae en el fallback: celdas apagadas,
  # nada configurable -- ParametrosCatalogo.tipo_elegible?/1 es la MISMA
  # regla que usa el motor para decidir si un campo participa de
  # Parámetro estándar, así la grilla nunca puede mostrar interactivo
  # algo que el motor de todos modos va a ignorar.
  attr :campo, :map, required: true
  attr :tipo_efectivo, :any, required: true
  attr :modos_fecha_rango, :list, required: true
  attr :modos_fecha_simple, :list, required: true
  attr :catalogos_referenciables, :list, required: true
  attr :detalles_por_catalogo, :map, required: true
  attr :form_id, :string, required: true

  def celdas_parametro(%{campo: %{"visible" => true, "es_parametro" => true}, tipo_efectivo: "date"} = assigns) do
    id = identificador(assigns.campo)
    assigns = assign(assigns, :id, id)

    ~H"""
    <td class="px-1.5 py-1.5 text-gray-500">Fecha</td>
    <td class="px-1.5 py-1.5 text-center"><.toggle_acotado campo={@campo} id={@id} /></td>
    <td class="px-1.5 py-1.5"><.defaults_fecha campo={@campo} id={@id} form_id={@form_id} modos_fecha_rango={@modos_fecha_rango} modos_fecha_simple={@modos_fecha_simple} /></td>
    """
  end

  def celdas_parametro(%{campo: %{"visible" => true, "es_parametro" => true}, tipo_efectivo: tipo} = assigns) when tipo in ~w(string referencia) do
    id = identificador(assigns.campo)
    tipo_filtro = assigns.campo["tipo_filtro"] || "like"
    origen = if tipo == "referencia", do: "referenciado", else: assigns.campo["origen"] || "libre"
    assigns = assigns |> assign(:id, id) |> assign(:tipo_filtro, tipo_filtro) |> assign(:origen, origen) |> assign(:es_referencia_real?, tipo == "referencia")

    ~H"""
    <td class="px-1.5 py-1.5">
      <.selector_tipo_filtro id={@id} form_id={@form_id} valor={@tipo_filtro} opciones={[{"like", "Contiene"}, {"igual", "Igual"}, {"multi", "Múltiple"}]} />
    </td>
    <td class="px-1.5 py-1.5 text-center text-[10px] text-gray-300" title="String nunca es acotado">No</td>
    <td class="px-1.5 py-1.5">
      <.origen_string campo={@campo} id={@id} form_id={@form_id} tipo_filtro={@tipo_filtro} origen={@origen} es_referencia_real?={@es_referencia_real?} catalogos_referenciables={@catalogos_referenciables} />
      <.defaults_string campo={@campo} id={@id} form_id={@form_id} tipo_filtro={@tipo_filtro} origen={@origen} detalles_por_catalogo={@detalles_por_catalogo} />
    </td>
    """
  end

  def celdas_parametro(%{campo: %{"visible" => true, "es_parametro" => true}, tipo_efectivo: tipo} = assigns) when tipo in ~w(integer decimal) do
    id = identificador(assigns.campo)
    acotado = assigns.campo["acotado"] || false
    tipo_filtro = if acotado, do: "entre", else: assigns.campo["tipo_filtro"] || "mayor"
    assigns = assigns |> assign(:id, id) |> assign(:acotado, acotado) |> assign(:tipo_filtro, tipo_filtro)

    ~H"""
    <td class="px-1.5 py-1.5">
      <span :if={@acotado} class="text-[10px] text-gray-500">Entre</span>
      <.selector_tipo_filtro :if={!@acotado} id={@id} form_id={@form_id} valor={@tipo_filtro} opciones={[{"mayor", "Mayor que"}, {"menor", "Menor que"}, {"igual", "Igual"}, {"diferente", "Diferente de"}]} />
    </td>
    <td class="px-1.5 py-1.5 text-center"><.toggle_acotado campo={@campo} id={@id} /></td>
    <td class="px-1.5 py-1.5"><.defaults_numerico campo={@campo} id={@id} form_id={@form_id} acotado={@acotado} /></td>
    """
  end

  def celdas_parametro(assigns) do
    ~H"""
    <td colspan="3" class="px-1.5 py-1.5 text-center text-gray-300" title="No visible o tipo sin parámetro estándar">—</td>
    """
  end

  attr :campo, :map, required: true
  attr :id, :string, required: true

  # Gate explícito: un campo elegible por tipo NO es parámetro del
  # reporte hasta que el admin lo prenda acá a propósito. Exige
  # "visible" == true -- "Parámetro" recién se puede prender después de
  # "Guardar columnas" con esa casilla tildada.
  def toggle_es_parametro(assigns) do
    ~H"""
    <button type="button" phx-click="cambiar_es_parametro" phx-value-campo={@id}
      disabled={@campo["visible"] != true}
      title={if @campo["visible"] != true, do: "Primero marcá \"Visible\" y guardá columnas -- Parámetro exige que la columna sea visible"}
      class={[
        "text-[10px] font-semibold rounded-full px-2 py-1",
        @campo["es_parametro"] && "bg-purple-600 text-white",
        !@campo["es_parametro"] && "bg-gray-100 text-gray-500 hover:bg-gray-200",
        @campo["visible"] != true && "opacity-40 cursor-not-allowed"
      ]}>
      {if @campo["es_parametro"], do: "Sí", else: "No"}
    </button>
    """
  end

  attr :id, :string, required: true
  attr :form_id, :string, required: true
  attr :valor, :string, required: true
  attr :opciones, :list, required: true

  def selector_tipo_filtro(assigns) do
    ~H"""
    <select phx-change="cambiar_tipo_filtro" form={@form_id} name={"tipo_filtro[#{@id}]"}
      class="border border-gray-300 rounded-lg text-[11px] px-2 py-1">
      <option :for={{valor, etiqueta} <- @opciones} value={valor} selected={valor == @valor}>{etiqueta}</option>
    </select>
    """
  end

  attr :campo, :map, required: true
  attr :id, :string, required: true

  def toggle_acotado(assigns) do
    ~H"""
    <button type="button" phx-click="cambiar_acotado" phx-value-campo={@id}
      class={[
        "text-[10px] font-semibold rounded-full px-2 py-1",
        @campo["acotado"] && "bg-purple-600 text-white",
        !@campo["acotado"] && "bg-gray-100 text-gray-500 hover:bg-gray-200"
      ]}>
      {if @campo["acotado"], do: "Sí", else: "No"}
    </button>
    """
  end

  attr :campo, :map, required: true
  attr :id, :string, required: true
  attr :form_id, :string, required: true
  attr :modos_fecha_rango, :list, required: true
  attr :modos_fecha_simple, :list, required: true

  def defaults_fecha(assigns) do
    modos = if assigns.campo["acotado"], do: assigns.modos_fecha_rango, else: assigns.modos_fecha_simple
    defaults = assigns.campo["defaults"] || %{}
    assigns = assigns |> assign(:modos, modos) |> assign(:defaults, defaults)

    ~H"""
    <div class="flex flex-col gap-1">
      <div class="flex items-center gap-1 flex-wrap">
        <button :for={{modo, etiqueta} <- @modos} type="button"
          phx-click="cambiar_defaults_modo" phx-value-campo={@id} phx-value-modo={modo}
          class={[
            "text-[10px] font-semibold rounded-full px-2 py-1 whitespace-nowrap",
            (@defaults["modo"] || "") == modo && "bg-purple-600 text-white",
            (@defaults["modo"] || "") != modo && "bg-purple-50 text-purple-700 hover:bg-purple-100"
          ]}>
          {etiqueta}
        </button>
      </div>

      <div :if={@defaults["modo"] == "formula" && @campo["acotado"]} class="flex items-center gap-1 mt-1">
        <input type="text" value={@defaults["valor"]} placeholder="primer_dia_mes"
          phx-change="cambiar_defaults_valor" form={@form_id} name={"defaults_valor[#{@id}]"}
          class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-20" />
        <span class="text-gray-400 text-[10px]">–</span>
        <input type="text" value={@defaults["valor_hasta"]} placeholder="actual"
          phx-change="cambiar_defaults_valor_hasta" form={@form_id} name={"defaults_valor_hasta[#{@id}]"}
          class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-20" />
      </div>

      <input :if={@defaults["modo"] == "formula" && !@campo["acotado"]} type="text" value={@defaults["valor"]} placeholder="ej. actual - 3 meses"
        phx-change="cambiar_defaults_valor" form={@form_id} name={"defaults_valor[#{@id}]"}
        class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-full mt-1" />
    </div>
    """
  end

  attr :campo, :map, required: true
  attr :id, :string, required: true
  attr :form_id, :string, required: true
  attr :tipo_filtro, :string, required: true
  attr :origen, :string, required: true
  attr :es_referencia_real?, :boolean, required: true
  attr :catalogos_referenciables, :list, required: true

  def origen_string(%{es_referencia_real?: true} = assigns) do
    ~H"""
    <span class="text-[10px] text-gray-500">Referenciado</span>
    """
  end

  def origen_string(%{tipo_filtro: "like"} = assigns) do
    ~H"""
    <span class="text-[10px] text-gray-500">Libre</span>
    """
  end

  def origen_string(%{tipo_filtro: "multi"} = assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <span class="text-[10px] text-gray-500">Referenciado</span>
      <.selector_catalogo id={@id} form_id={@form_id} valor={@campo["catalogo_referenciado"]} catalogos_referenciables={@catalogos_referenciables} />
    </div>
    """
  end

  def origen_string(%{tipo_filtro: "igual"} = assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div class="flex gap-1">
        <button :for={{valor, etiqueta} <- [{"libre", "Libre"}, {"referenciado", "Referenciado"}]} type="button"
          phx-click="cambiar_origen" phx-value-campo={@id} phx-value-origen={valor}
          class={[
            "text-[10px] font-semibold rounded-full px-2 py-1",
            @origen == valor && "bg-purple-600 text-white",
            @origen != valor && "bg-purple-50 text-purple-700 hover:bg-purple-100"
          ]}>
          {etiqueta}
        </button>
      </div>
      <.selector_catalogo :if={@origen == "referenciado"} id={@id} form_id={@form_id} valor={@campo["catalogo_referenciado"]} catalogos_referenciables={@catalogos_referenciables} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :form_id, :string, required: true
  attr :valor, :any, required: true
  attr :catalogos_referenciables, :list, required: true

  def selector_catalogo(assigns) do
    ~H"""
    <select phx-change="cambiar_catalogo_referenciado" form={@form_id} name={"catalogo_referenciado[#{@id}]"}
      class="border border-gray-300 rounded text-[10px] px-1.5 py-0.5">
      <option value="" selected={@valor in [nil, ""]}>— elegir catálogo —</option>
      <option :for={c <- @catalogos_referenciables} value={c.nombre} selected={c.nombre == @valor}>{c.etiqueta}</option>
    </select>
    """
  end

  attr :campo, :map, required: true
  attr :id, :string, required: true
  attr :form_id, :string, required: true
  attr :tipo_filtro, :string, required: true
  attr :origen, :string, required: true
  attr :detalles_por_catalogo, :map, required: true

  # "like" y "igual"+libre -- caja de texto para un default fijo.
  def defaults_string(%{tipo_filtro: tipo_filtro, origen: origen} = assigns) when tipo_filtro == "like" or (tipo_filtro == "igual" and origen == "libre") do
    defaults = assigns.campo["defaults"] || %{}
    assigns = assign(assigns, :valor, defaults["valor"])

    ~H"""
    <input type="text" value={@valor} placeholder="Default (opcional)"
      phx-change="cambiar_defaults_valor" form={@form_id} name={"defaults_valor[#{@id}]"}
      class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-full" />
    """
  end

  # "igual"+referenciado (incluye tipo "referencia" real) -- un <select>
  # con los valores reales del catálogo, no una caja de texto libre.
  def defaults_string(%{tipo_filtro: "igual"} = assigns) do
    opciones = opciones_catalogo_referenciado(assigns.campo, assigns.detalles_por_catalogo)
    defaults = assigns.campo["defaults"] || %{}
    assigns = assigns |> assign(:opciones, opciones) |> assign(:valor, defaults["valor"])

    ~H"""
    <select phx-change="cambiar_defaults_valor" form={@form_id} name={"defaults_valor[#{@id}]"}
      class="border border-gray-300 rounded text-[11px] px-1.5 py-0.5 w-full">
      <option value="" selected={@valor in [nil, ""]}>— sin default —</option>
      <option :for={{val, etiqueta} <- @opciones} value={val} selected={to_string(val) == to_string(@valor)}>{etiqueta}</option>
    </select>
    """
  end

  # "multi" -- lookup con checkbox a la izquierda (SelectorMultipleComponents),
  # reemplaza el <select multiple> nativo (ctrl/cmd+click no es discoverable).
  def defaults_string(%{tipo_filtro: "multi"} = assigns) do
    opciones = opciones_catalogo_referenciado(assigns.campo, assigns.detalles_por_catalogo)
    defaults = assigns.campo["defaults"] || %{}
    valores = Enum.map(defaults["valores"] || [], &to_string/1)
    assigns = assigns |> assign(:opciones, opciones) |> assign(:valores, valores)

    ~H"""
    <.selector_multiple id={"defaults-#{@id}"} form_id={@form_id}
      evento="cambiar_defaults_valores" evento_todos="marcar_defaults_todos" evento_ninguno="limpiar_defaults_valores"
      campo_clave={@id} opciones={@opciones} seleccionados={@valores} />
    """
  end

  defp opciones_catalogo_referenciado(campo, detalles_por_catalogo) do
    case ParametrosCatalogo.props_referenciado(campo, detalles_por_catalogo) do
      nil -> []
      props -> CatalogoGenerico.opciones_referencia(props, %{}, nil)
    end
  end

  attr :campo, :map, required: true
  attr :id, :string, required: true
  attr :form_id, :string, required: true
  attr :acotado, :boolean, required: true

  def defaults_numerico(assigns) do
    defaults = assigns.campo["defaults"] || %{}
    assigns = assign(assigns, :defaults, defaults)

    ~H"""
    <div :if={@acotado} class="flex items-center gap-1">
      <input type="number" step="any" value={@defaults["valor"]} placeholder="Desde"
        phx-change="cambiar_defaults_valor" form={@form_id} name={"defaults_valor[#{@id}]"}
        class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-20" />
      <span class="text-gray-400 text-[10px]">–</span>
      <input type="number" step="any" value={@defaults["valor_hasta"]} placeholder="Hasta"
        phx-change="cambiar_defaults_valor_hasta" form={@form_id} name={"defaults_valor_hasta[#{@id}]"}
        class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-20" />
    </div>
    <input :if={!@acotado} type="number" step="any" value={@defaults["valor"]} placeholder="Default (opcional)"
      phx-change="cambiar_defaults_valor" form={@form_id} name={"defaults_valor[#{@id}]"}
      class="border border-gray-300 rounded px-1.5 py-0.5 text-[11px] w-full" />
    """
  end

  # --- Celda de Totales (Tot.) -- unifica lo que antes era
  # panel_filtros_resumen/1 (4 botones en filas separadas) en una sola
  # celda de la grilla. Mín./Máx./Total página/Total general son chips
  # inline (mismo patrón visual/evento que ya probó producción); Máscara
  # es un popover chico aparte porque son 2 <select> -- no entran cómodos
  # como chip. Solo campos numéricos (integer/decimal) tienen algo que
  # mostrar acá -- "referencia" queda afuera (un id no es sumable), igual
  # criterio que ya tenía panel_filtros_resumen.
  attr :campo, :map, required: true
  attr :id, :string, required: true
  attr :form_id, :string, required: true
  attr :tipo_efectivo, :any, required: true

  def celda_totales(%{tipo_efectivo: tipo} = assigns) when tipo in ~w(integer decimal) do
    props = assigns.campo
    assigns =
      assigns
      |> assign(:activo?, props["agregacion_activa"] == true)
      |> assign(:minmax?, props["minmax_recomendado"] == true)
      |> assign(:pagina?, props["total_pagina_activo"] == true)
      |> assign(:general?, props["total_general_activo"] == true)

    ~H"""
    <div class="flex flex-col gap-1.5">
      <button type="button" phx-click="cambiar_agregacion_activa" phx-value-campo={@id} phx-value-activo={to_string(!@activo?)}
        title={if @activo?, do: "Totaliza -- clic para desactivar", else: "No totaliza -- clic para activar"}
        class={[
          "text-[10px] font-semibold rounded-full px-2 py-1 w-fit",
          @activo? && "bg-purple-600 text-white",
          !@activo? && "bg-gray-100 text-gray-500 hover:bg-gray-200"
        ]}>
        {if @activo?, do: "Tot", else: "No"}
      </button>

      <div :if={@activo?} class="flex items-center gap-1 flex-wrap">
        <button type="button" phx-click="cambiar_minmax_recomendado" phx-value-campo={@id} phx-value-recomendado={to_string(!@minmax?)}
          title="Mostrar siempre el mínimo y el máximo en la fila de Resumen"
          class={["text-[9px] font-semibold rounded-full px-1.5 py-0.5", @minmax? && "bg-green-600 text-white", !@minmax? && "bg-gray-100 text-gray-500 hover:bg-gray-200"]}>
          Mín/Máx
        </button>
        <button type="button" phx-click="cambiar_total_pagina" phx-value-campo={@id} phx-value-activo={to_string(!@pagina?)}
          title="Suma de SOLO los registros de la página actual"
          class={["text-[9px] font-semibold rounded-full px-1.5 py-0.5", @pagina? && "bg-green-600 text-white", !@pagina? && "bg-gray-100 text-gray-500 hover:bg-gray-200"]}>
          Pág
        </button>
        <button type="button" phx-click="cambiar_total_general" phx-value-campo={@id} phx-value-activo={to_string(!@general?)}
          title="Suma de TODOS los registros que matchean el filtro/búsqueda"
          class={["text-[9px] font-semibold rounded-full px-1.5 py-0.5", @general? && "bg-green-600 text-white", !@general? && "bg-gray-100 text-gray-500 hover:bg-gray-200"]}>
          Gral
        </button>
      </div>

      <form :if={@activo?} phx-change="cambiar_mascara" class="flex items-center gap-1">
        <input type="hidden" name="campo" value={@id} />
        <select name="separador" title="Separador de miles" class="text-[9px] text-gray-600 border border-gray-200 rounded px-1 py-0.5">
          <option value="," selected={Map.get(@campo, "mascara_separador", ",") == ","}>1,234</option>
          <option value="." selected={Map.get(@campo, "mascara_separador", ",") == "."}>1.234</option>
        </select>
        <select name="simbolo" title="Símbolo" class="text-[9px] text-gray-600 border border-gray-200 rounded px-1 py-0.5">
          <option value="" selected={Map.get(@campo, "mascara_simbolo", "") == ""}>Sin $</option>
          <option value="$" selected={Map.get(@campo, "mascara_simbolo", "") == "$"}>$</option>
        </select>
      </form>
    </div>
    """
  end

  def celda_totales(assigns) do
    ~H"""
    <span class="text-gray-300 text-[11px]">—</span>
    """
  end
end
