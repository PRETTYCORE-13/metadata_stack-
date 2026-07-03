defmodule MetadataApp.Catalogos.PtyMotos do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_motos", campos: [{:pty_moto_nombre, :string, %{longitud: 30, formato: nil}}, {:pty_moto_tipo, :string, %{longitud: 20, formato: nil}}]
end
