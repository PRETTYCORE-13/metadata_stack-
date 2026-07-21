defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyCanales.Pre do
  @behaviour MetadataApp.MetaStateEngine.ReglaPre

  @impl true
  def evaluar(accion, _registro, _contexto) do
    case accion do
      "nuevo" ->
        # ESCRIBA SU CODIGO AQUÍ
        :ok

      "registrar" ->
        # ESCRIBA SU CODIGO AQUÍ
        :ok

      _ -> :ok
    end
  end
end
