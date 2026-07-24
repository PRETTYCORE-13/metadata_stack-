defmodule MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureEquipo do
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "meta_fixture_equipo", campos: [{:meta_fixture_equipo_nombre_equipo, :string, %{valor_default: nil, opcional: false, longitud: 100, formato: nil}}]
end
