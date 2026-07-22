defmodule MetadataApp.MetaBusinessProcess.Catalogos.PtyPedidoEnc do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "pty_pedido_enc", campos: [{:pty_pedidoenc_sucursal, :string, %{opcional: false, longitud: 4, formato: nil}}, {:pty_pedidoenc_cliente, :string, %{opcional: false, longitud: 60, formato: nil}}, {:pty_pedidoenc_fecha, :date, %{opcional: false}}], transaccional: true, codigo_trn: "VEN2"
end
