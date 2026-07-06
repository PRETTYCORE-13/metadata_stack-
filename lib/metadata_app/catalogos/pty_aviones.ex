defmodule MetadataApp.Catalogos.PtyAviones do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_aviones", campos: [{:pty_aviones_nombre, :string, %{longitud: 20, formato: nil}}]
end
