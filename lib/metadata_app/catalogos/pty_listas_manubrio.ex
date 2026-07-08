defmodule MetadataApp.Catalogos.PtyListasManubrio do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_listas_manubrio", campos: [{:pty_nombre, :string, %{longitud: 20, formato: nil}}]
end
