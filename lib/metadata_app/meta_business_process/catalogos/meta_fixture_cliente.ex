defmodule MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "meta_fixture_cliente", campos: [{:meta_fixture_cliente_nombre, :string, %{formato: nil, longitud: 100, opcional: false, valor_default: nil}}, {:meta_fixture_cliente_edad, :integer, %{maximo: nil, minimo: nil, opcional: false, valor_default: nil}}, {:meta_fixture_cliente_venta, :decimal, %{escala: 2, maximo: nil, minimo: nil, opcional: false, precision: 10, valor_default: nil}}]
end
