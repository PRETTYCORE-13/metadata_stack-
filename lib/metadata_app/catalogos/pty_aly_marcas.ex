defmodule MetadataApp.Catalogos.PtyAlyMarcas do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_aly_marcas", campos: [{:pty_aly_marca_nombre, :string, %{formato: nil, longitud: 60, opcional: false}}, {:pty_aly_marca_orden, :integer, %{opcional: false, maximo: nil, minimo: nil}}]
end
