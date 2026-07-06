defmodule MetadataApp.Catalogos.PtyClientes do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_clientes", campos: [{:pty_clientes_nombre, :string, %{longitud: 150, formato: nil}}, {:pty_clientes_edad, :integer, %{maximo: nil, minimo: nil}}, {:pty_clientes_venta, :decimal, %{precision: 20, escala: 6, maximo: nil, minimo: nil}}]
end
