defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtySegmentos do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_segmentos", campos: [{:pty_segmento_nombre, :string, %{opcional: false, longitud: 15, formato: nil}}]
end
