defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyPedidoDet.Pre do
  @behaviour MetadataApp.MetaStateEngine.ReglaPre

  @impl true
  def evaluar(accion, _registro, _contexto) do
    case accion do

      _ -> :ok
    end
  end
end
