defmodule MetadataApp.Catalogos.PtyPapeleriaLapiz do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_papeleria_lapiz", campos: [{:pty_lapiz, :string, %{opcional: false, longitud: 255, formato: nil}}]
end
