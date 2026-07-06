defmodule MetadataApp.Catalogos.PtyCanal do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_canal", campos: [{:canal_nombre, :string, %{longitud: 150, formato: nil}}, {:canal_orden, :integer, %{maximo: nil, minimo: nil}}]
end
