defmodule MetadataApp.Catalogos.PtyCarros do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_carros", campos: [{:pty_carro_nombre, :string, %{longitud: 30, formato: nil}}, {:pty_carro_tipo, :string, %{longitud: 20, formato: nil}}]
end
