defmodule MetadataApp.Repo.Migrations.RestaurarTablaMetaFixtureEquipo do
  use Ecto.Migration

  # Réplica exacta de priv/repo/migrations/20260723220200_crear_meta_fixture_equipo.exs
  # (tabla borrada sin querer desde BC List, ver 20260727194501_restaurar_metadata_fixtures_de_test.exs).
  # Nombre de archivo renombrado 2026-08-27 -- ver el comentario grande en
  # 20260727194502_restaurar_tabla_meta_fixture_cliente.exs (bug real de
  # orden de migraciones, timestamp de 17 dígitos).
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
