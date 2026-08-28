defmodule MetadataApp.MetaBusinessProcess.Catalogos.CategoriasPrueba do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "categorias_prueba", campos: [{:categorias_prueba_nombre, :string, %{formato: nil, longitud: 100, longitud_minima: nil, opcional: false, transformacion: nil, valor_default: nil}}]
end
