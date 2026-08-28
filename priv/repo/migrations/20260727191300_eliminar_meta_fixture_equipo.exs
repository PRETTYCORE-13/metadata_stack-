defmodule MetadataApp.Repo.Migrations.EliminarMetaFixtureEquipo do
  use Ecto.Migration

  def change do
    drop table(:meta_fixture_equipo)
  end
end
