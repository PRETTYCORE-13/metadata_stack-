defmodule MetadataApp.Repo.Migrations.EliminarMetaFixtureEquipo20260727191255132 do
  use Ecto.Migration

  def change do
    drop table(:meta_fixture_equipo)
  end
end
