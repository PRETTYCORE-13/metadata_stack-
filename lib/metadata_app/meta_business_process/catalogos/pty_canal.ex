defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtyCanal do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_canal", campos: [{:canal_nombre, :string, %{opcional: false, longitud: 150, formato: nil}}, {:canal_orden, :integer, %{opcional: false, maximo: nil, minimo: nil}}]
end
