defmodule MetadataApp.MetaBusinessProcess.Catalogos.ValBundleColumnas do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "_val_bundle_columnas", campos: [{:nombre, :string, %{formato: nil, longitud: 255, longitud_minima: nil, opcional: false, transformacion: nil, valor_default: nil}}]
end
