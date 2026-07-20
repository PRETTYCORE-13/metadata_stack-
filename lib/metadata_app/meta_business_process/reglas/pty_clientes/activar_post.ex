defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyClientes.ActivarPost do
  @behaviour MetadataApp.MetaStateEngine.ReglaPost

  @impl true
  def ejecutar(_registro, _contexto, _params, _repo) do
    # ESCRIBA SUS REGLAS AQUI
    {:ok, :sin_cambios}
  end
end
