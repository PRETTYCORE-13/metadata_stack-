defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyMotocicletas.DarDeBajaPost do
  @behaviour MetadataApp.MetaStateEngine.ReglaPost

  require Logger

  @impl true
  def ejecutar(registro, contexto, _params, _repo) do
    Logger.info("moto #{registro.id} dada de baja (motivo: #{Map.get(contexto, "motivo_baja")})")
    {:ok, :sin_cambios}
  end
end
