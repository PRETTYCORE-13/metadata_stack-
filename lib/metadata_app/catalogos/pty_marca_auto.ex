defmodule MetadataApp.Catalogos.PtyMarcaAuto do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_marca_autos", campos: [{:pty_marca_auto_nombre, :string, 20}]
end
