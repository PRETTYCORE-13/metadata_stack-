defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyMotocicletas.DarDeBajaPre do
  @behaviour MetadataApp.MetaStateEngine.ReglaPre

  @impl true
  def evaluar(_registro, contexto, _params) do
    case Map.get(contexto, "motivo_baja") do
      motivo when is_binary(motivo) and motivo != "" -> :ok
      _ -> {:error, "hay que indicar motivo_baja para dar de baja una moto"}
    end
  end
end
