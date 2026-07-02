defmodule MetadataApp.Catalogos.PtyCanal do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_canales", campos: [{:canal_nombre, :string, 10}, {:canal_factor1, :decimal, nil}, {:canal_factor2, :integer, nil}, {:canal_factor3, :integer, nil}, {:canal_orden, :integer, nil}]
end
