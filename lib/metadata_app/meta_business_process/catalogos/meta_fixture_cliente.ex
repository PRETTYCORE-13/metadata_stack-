defmodule MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "meta_fixture_cliente", campos: [{:meta_fixture_cliente_nombre, :string, %{valor_default: nil, opcional: false, longitud: 100, formato: nil}}, {:meta_fixture_cliente_edad, :integer, %{valor_default: nil, opcional: false, minimo: nil, maximo: nil}}, {:meta_fixture_cliente_venta, :decimal, %{precision: 10, valor_default: nil, opcional: false, minimo: nil, maximo: nil, escala: 2}}]
end
