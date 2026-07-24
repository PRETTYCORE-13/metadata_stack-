defmodule MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureEquipo do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "meta_fixture_equipo", campos: [{:meta_fixture_equipo_nombre_equipo, :string, %{formato: nil, longitud: 100, opcional: false, valor_default: nil}}]
end
