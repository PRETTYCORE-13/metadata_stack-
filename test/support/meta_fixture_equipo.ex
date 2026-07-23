defmodule MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureEquipo do
  @moduledoc false
  # Fixture de test permanente — ver migración
  # priv/repo/migrations/20260723220000_crear_fixtures_de_test.exs
  # (reemplaza a pty_equipos_nfl, mismo motivo que MetaFixtureCliente).
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico,
    tabla: "meta_fixture_equipo",
    campos: [
      {:meta_fixture_equipo_nombre_equipo, :string, %{}}
    ]
end
