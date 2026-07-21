defmodule MetadataApp.MetaBusinessProcess.Reglas.PtySegmentos.Post do
  @behaviour MetadataApp.MetaStateEngine.ReglaPost

  @impl true
  def ejecutar(accion, _registro, _contexto, _repo) do
    case accion do
      "alta" ->

        {:ok, :sin_cambios}

      "guardar" ->

        {:ok, :sin_cambios}

      _ -> {:ok, :sin_cambios}
    end
  end
end
