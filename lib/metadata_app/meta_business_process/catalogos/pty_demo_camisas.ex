defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtyDemoCamisas do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_demo_camisas", campos: [{:pty_nombre, :string, %{opcional: false, longitud: 80, formato: nil}}, {:pty_precio, :decimal, %{precision: 10, opcional: false, escala: 2, maximo: nil, minimo: nil}}, {:pty_disponible, :boolean, %{opcional: false}}]
end
