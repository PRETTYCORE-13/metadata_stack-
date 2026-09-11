defmodule MetadataAppWeb.FiltrosDefaultComponents do
  @moduledoc """
  Panel "Filtros por default" (fecha de alta) — extraído de BcMotorLive para
  que cualquier otra pantalla de configuración lo reuse tal cual, sin copiar
  el HEEx. El LiveView que lo use tiene que:

    - Pasar `header` (BusinessProcessBuilder.MetaSchema.Header) como assign.
    - Implementar `handle_event` para "cambiar_filtro_fecha_modo" (recibe
      `"modo"`, uno de `MetadataApp.FiltrosDefault.modos_fecha/0`) — ver
      BcMotorLive para la referencia de cómo persistir el campo en el
      header vía MetaSchemaContext.actualizar_header/2.

  2026-09-11 (SPEC-SYS-1109202606): este panel llegó a tener una rama
  de UI para un séptimo modo, "rango" (fecha fija desde/hasta, con el
  hook "AbrirCalendario"), que ningún botón real podía activar y que
  `FiltrosDefault.rango_fecha/3` tampoco implementaba — código muerto
  de una versión anterior del vocabulario de modos, eliminado.
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
      </div>
    </div>
    """
  end
end
