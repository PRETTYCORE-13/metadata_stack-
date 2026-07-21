defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyMaterial.Pre do
  @behaviour MetadataApp.MetaStateEngine.ReglaPre

  @impl true
  def evaluar(accion, _registro, _contexto) do
    case accion do
      "alta" ->
        if _registro.pty_material_fecha_baja == nil do
          :ok
        else
          {:error, "en alta, la fecha de baja debe estar vacía"}
        end

      "baja" ->

        :ok

      "guardar" ->

        :ok

      "reactiva" ->

        :ok

      _ -> :ok
    end
  end
end
