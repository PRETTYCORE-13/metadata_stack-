defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtyListasCarros do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_listas_carros", campos: [{:nombre, :string, %{opcional: false, longitud: 255, formato: nil}}]
end
