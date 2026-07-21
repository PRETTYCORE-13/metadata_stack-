defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyClientes.Pre do
  @behaviour MetadataApp.MetaStateEngine.ReglaPre

  @impl true
  def evaluar(accion, _registro, _contexto) do
    case accion do
      "activar" ->

        :ok

      "calificar" ->

        :ok

      "dar_de_baja" ->

        :ok

      "guardar" ->

        :ok

      "reactivar" ->

        :ok

      _ -> :ok
    end
  end
end
