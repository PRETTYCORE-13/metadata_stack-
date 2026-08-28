defmodule MetadataApp.MetaBusinessProcess.Catalogos.LotesPruebaMultinivel do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "lotes_prueba_multinivel", campos: [{:lotes_prueba_multinivel_numero_lote, :string, %{formato: nil, longitud: 30, longitud_minima: nil, opcional: false, transformacion: nil, valor_default: nil}}], detalle_de: "partidas_prueba_multinivel"
end
