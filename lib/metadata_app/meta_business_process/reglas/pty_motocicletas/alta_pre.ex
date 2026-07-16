defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyMotocicletas.AltaPre do
  @behaviour MetadataApp.MetaStateEngine.ReglaPre

  @impl true
  def evaluar(registro, _contexto, _params) do
    if registro.pty_motocicletas_numero_cilindros > 0 do
      :ok
    else
      {:error, "numero_cilindros tiene que ser mayor a 0"}
    end
  end
end
