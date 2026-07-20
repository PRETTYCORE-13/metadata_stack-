defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtyCanales do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_canales", campos: [{:pty_canal_descripcion, :string, %{formato: nil, longitud: 60, opcional: false}}, {:pty_canal_orden, :integer, %{minimo: nil, maximo: nil, opcional: false}}]
end
