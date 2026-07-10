defmodule MetadataApp.Repo.Migrations.CrearPtyEquiposNfl20260710200658414 do
  use Ecto.Migration

  def change do
    create table(:pty_equipos_nfl) do
      add :pty_equipos_nfl_nombre_equipo, :string, size: 60, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_equipos_nfl, [:pty_equipos_nfl_nombre_equipo], name: :pty_equipos_nfl_unico_index)
  end
end
