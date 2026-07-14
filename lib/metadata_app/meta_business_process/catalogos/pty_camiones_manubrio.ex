defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtyCamionesManubrio do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_camiones_manubrio", campos: [{:pty_nombre, :string, %{longitud: 255, formato: nil, opcional: false}}]
end
