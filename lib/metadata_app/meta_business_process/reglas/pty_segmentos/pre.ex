defmodule MetadataApp.MetaBusinessProcess.Reglas.PtySegmentos.Pre do
  @behaviour MetadataApp.MetaStateEngine.ReglaPre

  @impl true
  def evaluar(accion, _registro, _contexto) do
    case accion do
      "alta" ->

        :ok

      "guardar" ->

        :ok

      _ -> :ok
    end
  end
end
