defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyMotocicletas.GuardarPost do
  @behaviour MetadataApp.MetaStateEngine.ReglaPost

  require Logger

  @impl true
  def ejecutar(registro, _contexto, _params, _repo) do
    Logger.info("moto #{registro.id} actualizada (placas #{registro.pty_motocicletas_numero_placas})")
    {:ok, :sin_cambios}
  end
end
