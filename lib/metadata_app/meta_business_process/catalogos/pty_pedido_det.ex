defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtyPedidoDet do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_pedido_det", campos: [{:pty_pedidodet_producto, :string, %{opcional: false, longitud: 15, formato: nil}}, {:pty_pedidodet_cantidad, :integer, %{opcional: false, maximo: nil, minimo: nil}}, {:pty_pedidodet_precio, :decimal, %{precision: 20, opcional: false, escala: 2, maximo: nil, minimo: nil}}], detalle_de: "pty_pedido_enc"
end
