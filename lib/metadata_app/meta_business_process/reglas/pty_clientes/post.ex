defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyClientes.Post do
  @behaviour MetadataApp.MetaStateEngine.ReglaPost

  @impl true
  def ejecutar(accion, _registro, _contexto, _repo) do
    case accion do
      "activar" ->
        
        {:ok, :sin_cambios}

      "calificar" ->
        
        {:ok, :sin_cambios}

      "dar_de_baja" ->
        
        {:ok, :sin_cambios}

      "guardar" ->
        
        {:ok, :sin_cambios}

      "reactivar" ->
        
        {:ok, :sin_cambios}

      _ -> {:ok, :sin_cambios}
    end
  end
end
