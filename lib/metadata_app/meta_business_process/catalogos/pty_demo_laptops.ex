defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtyDemoLaptops do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_demo_laptops", campos: [{:pty_modelo, :string, %{opcional: false, longitud: 80, formato: nil}}, {:pty_precio, :decimal, %{precision: 10, opcional: false, escala: 2, maximo: nil, minimo: nil}}, {:pty_stock, :integer, %{opcional: false, maximo: nil, minimo: nil}}]
end
