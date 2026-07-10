defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtyVehiculosCarros do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_vehiculos_carros", campos: [{:ss, :string, %{opcional: false, longitud: 1, formato: nil}}]
end
