defmodule MetadataApp.Repo.Migrations.RestaurarTablaMetaFixtureEquipo do
  use Ecto.Migration

  # Réplica exacta de priv/repo/migrations/20260723222644223_crear_meta_fixture_equipo_20260723222644223.exs
  # (tabla borrada sin querer desde BC List, ver 20260727193414_restaurar_metadata_fixtures_de_test.exs).
  def change do
    create table(:meta_fixture_equipo) do
      add :meta_fixture_equipo_nombre_equipo, :string, size: 100, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:meta_fixture_equipo, [:meta_fixture_equipo_nombre_equipo], name: :meta_fixture_equipo_unico_index)
  end
end
