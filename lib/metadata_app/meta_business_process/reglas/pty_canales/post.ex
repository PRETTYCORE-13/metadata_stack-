defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyCanales.Post do
  @behaviour MetadataApp.MetaStateEngine.ReglaPost

  @impl true
  def ejecutar(accion, _registro, _contexto, _repo) do
    case accion do
      "nuevo" ->
        # ESCRIBA SU CODIGO AQUÍ
        {:ok, :sin_cambios}

      "registrar" ->
        # ESCRIBA SU CODIGO AQUÍ
        {:ok, :sin_cambios}

      _ -> {:ok, :sin_cambios}
    end
  end
end
