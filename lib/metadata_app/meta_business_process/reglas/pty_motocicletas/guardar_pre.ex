defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyMotocicletas.GuardarPre do
  @behaviour MetadataApp.MetaStateEngine.ReglaPre

  @impl true
  def evaluar(registro, _contexto, _params) do
    if String.trim(registro.pty_motocicletas_numero_placas) == "" do
      {:error, "numero_placas no puede quedar vacío"}
    else
      :ok
    end
  end
end
