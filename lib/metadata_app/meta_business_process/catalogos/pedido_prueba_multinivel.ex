defmodule MetadataApp.MetaBusinessProcess.Catalogos.PedidoPruebaMultinivel do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pedido_prueba_multinivel", campos: [{:pedido_prueba_multinivel_folio, :string, %{formato: nil, longitud: 20, longitud_minima: nil, opcional: false, transformacion: nil, valor_default: nil}}]
end
