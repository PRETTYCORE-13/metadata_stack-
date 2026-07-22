defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtyMarcas do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_marcas", campos: [{:pty_marcas_nombre, :string, %{opcional: false, longitud: 15, formato: nil}}], transaccional: true, codigo_trn: "VEN1"
end
