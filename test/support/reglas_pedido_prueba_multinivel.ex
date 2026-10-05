defmodule MetadataApp.MetaBusinessProcess.Reglas.PedidoPruebaMultinivel.Pre do
  @moduledoc false
  # PRE de prueba del maestro pedido_prueba_multinivel, para
  # SPEC-SYS-0510202601 (renglones_propuestos en la regla del encabezado,
  # ver test/metadata_app/meta_state_engine/renglones_propuestos_pre_test.exs).
  #
  # Avisa al proceso de la prueba qué renglones vio (la regla corre en el
  # mismo proceso que llama al motor) y solo rechaza con marcadores
  # explícitos, para no afectar a otras pruebas que usan este catálogo:
  #   - una partida "PROHIBIDO" entre las que quedarán;
  #   - folio "REQ-..." sin partidas al guardar;
  #   - una partida "BLOQUEA_BAJA" al dar de baja.
  @behaviour MetadataApp.MetaStateEngine.ReglaPre

  alias MetadataApp.Renglones

  @partidas "partidas_prueba_multinivel"

  @impl true
  def evaluar(accion, registro, contexto) do
    send(self(), {:pre_pedido, accion, contexto["renglones_propuestos"]})
    productos = contexto |> Renglones.vigentes(@partidas) |> Enum.map(& &1.partidas_prueba_multinivel_producto)

    cond do
      "PROHIBIDO" in productos ->
        {:error, "el pedido no puede llevar una partida PROHIBIDO"}

      accion == "guardar" and String.starts_with?(registro.pedido_prueba_multinivel_folio || "", "REQ-") and productos == [] ->
        {:error, "el pedido necesita al menos una partida"}

      accion == "baja" and "BLOQUEA_BAJA" in productos ->
        {:error, "una partida impide la baja"}

      true ->
        :ok
    end
  end
end
