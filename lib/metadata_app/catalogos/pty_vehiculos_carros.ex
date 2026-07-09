defmodule MetadataApp.Catalogos.PtyVehiculosCarros do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_vehiculos_carros", campos: [{:ss, :string, %{opcional: false, longitud: 1, formato: nil}}]
end
