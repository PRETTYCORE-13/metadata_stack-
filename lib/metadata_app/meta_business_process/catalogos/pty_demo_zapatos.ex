defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtyDemoZapatos do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_demo_zapatos", campos: [{:pty_nombre, :string, %{opcional: false, longitud: 80, formato: nil}}, {:pty_precio, :decimal, %{precision: 10, opcional: false, escala: 2, maximo: nil, minimo: nil}}, {:pty_talla, :integer, %{opcional: false, maximo: nil, minimo: nil}}]
end
