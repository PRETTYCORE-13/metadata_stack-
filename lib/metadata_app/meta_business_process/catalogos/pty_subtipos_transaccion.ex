defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtySubtiposTransaccion do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_subtipos_transaccion", campos: [{:tipo_transaccion, :integer, %{opcional: false, tabla_referenciada: "meta_schema_header", valor_default: nil}}, {:descripcion, :string, %{formato: nil, longitud: 255, longitud_minima: nil, opcional: false, transformacion: nil, valor_default: nil}}]
end
