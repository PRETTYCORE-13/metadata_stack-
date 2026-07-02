defmodule MetadataApp.Catalogos.Color do
  use MetadataApp.MetaCatalogoGenerico, tabla: "colores", campos: [{:nombre_color, :string, 25}]
end
