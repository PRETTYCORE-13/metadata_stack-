defmodule MetadataApp.MetaBusinessProcess.Catalogos.Demo100FinanzasCuentasPorPagarReg do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "demo100_finanzas_cuentas_por_pagar_reg", campos: [{:nombre, :string, %{formato: nil, longitud: 255, opcional: false, valor_default: nil}}, {:descripcion, :string, %{formato: nil, longitud: 255, opcional: false, valor_default: nil}}, {:activo, :boolean, %{opcional: false, valor_default: nil}}, {:cantidad, :integer, %{maximo: nil, minimo: nil, opcional: false, valor_default: nil}}]
end
