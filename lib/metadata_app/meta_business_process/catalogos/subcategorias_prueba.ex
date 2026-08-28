defmodule MetadataApp.MetaBusinessProcess.Catalogos.SubcategoriasPrueba do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "subcategorias_prueba", campos: [{:subcategorias_prueba_nombre, :string, %{formato: nil, longitud: 100, longitud_minima: nil, opcional: false, transformacion: nil, valor_default: nil}}, {:subcategorias_prueba_categoria, :integer, %{opcional: false, tabla_referenciada: "categorias_prueba", valor_default: nil}}]
end
