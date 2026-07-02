defmodule MetadataApp.Catalogos.Talla do
  use MetadataApp.MetaCatalogoGenerico, tabla: "tallas", campos: [{:nombre_talla, :string, 10}, {:segmento_talla, :string, 15}, {:tipo_talla, :string, 15}]
end
