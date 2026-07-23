defmodule MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "meta_fixture_cliente", campos: [{:meta_fixture_cliente_nombre, :string, %{opcional: false, valor_default: nil, longitud: 100, formato: nil}}, {:meta_fixture_cliente_edad, :integer, %{opcional: false, valor_default: nil, maximo: nil, minimo: nil}}, {:meta_fixture_cliente_venta, :decimal, %{precision: 10, opcional: false, valor_default: nil, escala: 2, maximo: nil, minimo: nil}}]
end
