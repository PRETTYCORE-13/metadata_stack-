defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyMotocicletas.AltaPost do
  @behaviour MetadataApp.MetaStateEngine.ReglaPost

  require Logger

  @impl true
  def ejecutar(registro, _contexto, _params, _repo) do
    Logger.info("moto #{registro.id} (#{registro.pty_motocicletas_numero_placas}) registrada")
    {:ok, :sin_cambios}
  end
end
