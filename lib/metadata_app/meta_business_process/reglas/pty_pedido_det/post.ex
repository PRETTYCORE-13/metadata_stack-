defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyPedidoDet.Post do
  @behaviour MetadataApp.MetaStateEngine.ReglaPost

  @impl true
  def ejecutar(accion, _registro, _contexto, _repo) do
    case accion do

      _ -> {:ok, :sin_cambios}
    end
  end
end
