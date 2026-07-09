defmodule MetadataApp.Repo.Migrations.CrearPtyVehiculosCarros20260709162557313 do
  use Ecto.Migration

  def change do
    create table(:pty_vehiculos_carros) do
      add :ss, :string, size: 1, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_vehiculos_carros, [:ss], name: :pty_vehiculos_carros_unico_index)
  end
end
