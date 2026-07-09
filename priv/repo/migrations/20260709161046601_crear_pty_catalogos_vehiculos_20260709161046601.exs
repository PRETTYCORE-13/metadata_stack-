defmodule MetadataApp.Repo.Migrations.CrearPtyCatalogosVehiculos20260709161046601 do
  use Ecto.Migration

  def change do
    create table(:pty_catalogos_vehiculos) do
      add :pty_nombre, :string, size: 255, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_catalogos_vehiculos, [:pty_nombre], name: :pty_catalogos_vehiculos_unico_index)
  end
end
