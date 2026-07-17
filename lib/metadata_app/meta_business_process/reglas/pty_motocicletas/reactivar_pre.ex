defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyMotocicletas.ReactivarPre do
  @behaviour MetadataApp.MetaStateEngine.ReglaPre

  @impl true
  def evaluar(registro, _contexto, _params) do
    if registro.pty_motocicletas_numero_cilindros > 0 do
      :ok
    else
      {:error, "no se puede reactivar una moto sin cilindros configurados"}
    end
  end
end
