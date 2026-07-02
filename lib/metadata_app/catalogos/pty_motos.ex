defmodule MetadataApp.Catalogos.PtyMotos do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_motos", campos: [{:pty_motos_nombre, :string, 30}, {:pty_motos_placa, :string, 10}, {:pty_motos_serie, :string, 20}]
end
