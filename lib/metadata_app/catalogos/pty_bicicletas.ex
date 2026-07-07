defmodule MetadataApp.Catalogos.PtyBicicletas do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_bicicletas", campos: [{:pty_nombre, :string, %{longitud: 20, formato: nil}}]
end
