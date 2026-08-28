defmodule MetadataApp.MetaBusinessProcess.Catalogos.PartidasPruebaMultinivel do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "partidas_prueba_multinivel", campos: [{:partidas_prueba_multinivel_producto, :string, %{formato: nil, longitud: 100, longitud_minima: nil, opcional: false, transformacion: nil, valor_default: nil}}], detalle_de: "pedido_prueba_multinivel"
end
