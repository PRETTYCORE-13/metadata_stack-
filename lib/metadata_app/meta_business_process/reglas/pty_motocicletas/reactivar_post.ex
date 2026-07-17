defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyMotocicletas.ReactivarPost do
  @behaviour MetadataApp.MetaStateEngine.ReglaPost

  require Logger

  @impl true
  def ejecutar(registro, _contexto, _params, _repo) do
    Logger.info("moto #{registro.id} reactivada")
    {:ok, :sin_cambios}
  end
end
