defmodule MetadataApp.Catalogos.PtyClientes do
  use MetadataApp.MetaCatalogoGenerico, tabla: "pty_clientes", campos: [{:pty_clientes_nombre, :string, %{opcional: false, longitud: 150, formato: nil}}, {:pty_clientes_edad, :integer, %{opcional: false, maximo: nil, minimo: nil}}, {:pty_clientes_venta, :decimal, %{precision: 20, opcional: false, escala: 6, maximo: nil, minimo: nil}}, {:pty_clientes_fecha_baja, :date, %{opcional: true}}]
end
