defmodule MetadataApp.Catalogos.PtyListasCarros do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_listas_carros", campos: [{:nombre, :string, %{opcional: false, longitud: 255, formato: nil}}]
end
