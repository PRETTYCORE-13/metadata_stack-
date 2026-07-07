defmodule MetadataApp.Catalogos.PtyBicis do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_bicis", campos: [{:pty_bicis, :string, %{longitud: 20, formato: nil}}]
end
