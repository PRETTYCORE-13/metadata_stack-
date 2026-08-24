defmodule MetadataAppWeb.FiltrosDefaultComponents do
  @moduledoc """
  Panel "Filtros por default" (fecha de alta) — extraído de BcMotorLive para
  que cualquier otra pantalla de configuración lo reuse tal cual, sin copiar
  el HEEx. El LiveView que lo use tiene que:

    - Pasar `header` (BusinessProcessBuilder.MetaSchema.Header) como assign.
    - Implementar `handle_event` para "cambiar_filtro_fecha_modo" (recibe
      `"modo"`) y "cambiar_filtro_fecha_valor" (recibe `"campo"` — "desde"
      o "hasta" — y `"valor"`) — ver BcMotorLive para la referencia de
      cómo persistir esos dos campos en el header vía
      MetaSchemaContext.actualizar_header/2 y qué funciones de
      `MetadataApp.FiltrosDefault` usar en el camino.
    - Tener el hook JS "AbrirCalendario" registrado en app.js (ya lo está,
      lo usan estos mismos `<input type="date">`).
  """
  use Phoenix.Component

  alias MetadataApp.FiltrosDefault

  attr :header, :any, required: true

  def panel_filtros_default(assigns) do
    ~H"""
    <div class="border border-gray-200 rounded-lg mt-4">
      <div class="px-1.5 ml-2 -mb-2 relative">
        <span class="bg-white px-1.5 font-bold uppercase tracking-wide text-[11px] text-gray-900">Filtros por default</span>
      </div>
      <div class="p-3 pt-4 overflow-x-auto">
        <p class="text-gray-500 mb-3">
          Acota lo que ve el usuario final apenas abre la tabla, por fecha de alta. Independiente de "Campos por default" — funciona solo, sin necesidad de activar aquello.
        </p>

        <div class="flex items-center gap-2 flex-wrap">
          <%= for {modo, etiqueta} <- FiltrosDefault.modos_fecha() do %>
            <button type="button"
              phx-click="cambiar_filtro_fecha_modo"
              phx-value-modo={modo}
              class={[
                "text-[11px] font-semibold rounded-lg px-3 py-1.5 transition-colors whitespace-nowrap",
                if((@header.filtro_default_fecha_modo || "") == modo,
                  do: "bg-purple-600 text-white",
                  else: "bg-purple-100 text-purple-700 hover:bg-purple-200"
                )
              ]}
            >
              {etiqueta}
            </button>
          <% end %>
        </div>

        <%= if @header.filtro_default_fecha_modo == "rango" do %>
          <div class="flex items-center gap-2 mt-2">
            <form phx-change="cambiar_filtro_fecha_valor">
              <input type="hidden" name="campo" value="desde" />
              <label class="text-[10px] text-gray-500 block mb-0.5">Desde</label>
              <div class="relative">
                <input
                  id="filtro-default-fecha-desde"
                  phx-hook="AbrirCalendario"
                  type="date"
                  name="valor"
                  value={@header.filtro_default_fecha_valor}
                  class="border border-gray-300 rounded-lg pl-2 pr-6 py-1 text-[11px]"
                />
                <button type="button" tabindex="-1" data-abrir-calendario aria-label="Abrir calendario"
                  class="pc-abrir-calendario absolute right-1 top-1/2 -translate-y-1/2 material-symbols-outlined" style="font-size:16px">expand_more</button>
              </div>
            </form>
            <form phx-change="cambiar_filtro_fecha_valor">
              <input type="hidden" name="campo" value="hasta" />
              <label class="text-[10px] text-gray-500 block mb-0.5">Hasta</label>
              <div class="relative">
                <input
                  id="filtro-default-fecha-hasta"
                  phx-hook="AbrirCalendario"
                  type="date"
                  name="valor"
                  value={@header.filtro_default_fecha_valor_hasta}
                  class="border border-gray-300 rounded-lg pl-2 pr-6 py-1 text-[11px]"
                />
                <button type="button" tabindex="-1" data-abrir-calendario aria-label="Abrir calendario"
                  class="pc-abrir-calendario absolute right-1 top-1/2 -translate-y-1/2 material-symbols-outlined" style="font-size:16px">expand_more</button>
              </div>
            </form>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
