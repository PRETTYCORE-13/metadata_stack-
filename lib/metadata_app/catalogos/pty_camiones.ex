defmodule MetadataApp.Catalogos.PtyCamiones do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_camiones", campos: [{:pty_camion_nombre, :string, %{longitud: 20, formato: nil}}]
end
