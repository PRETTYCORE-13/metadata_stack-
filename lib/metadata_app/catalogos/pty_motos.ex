defmodule MetadataApp.Catalogos.PtyMotos do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_motos", campos: [{:pty_moto_nombre, :string, 30}, {:pty_moto_tipo, :string, 15}, {:pty_moto_licencia, :string, 10}]
end
