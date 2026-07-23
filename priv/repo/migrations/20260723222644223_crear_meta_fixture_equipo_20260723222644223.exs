defmodule MetadataApp.Repo.Migrations.CrearMetaFixtureEquipo20260723222644223 do
  use Ecto.Migration

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
