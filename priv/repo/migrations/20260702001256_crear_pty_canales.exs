defmodule MetadataApp.Repo.Migrations.CrearPtyCanales do
  use Ecto.Migration

  def change do
    create table(:pty_canales) do
      add :canal_nombre, :string, size: 10, null: false
      add :canal_factor1, :string, size: 255, null: false
      add :canal_factor2, :integer, null: false
      add :canal_factor3, :integer, null: false
      add :canal_orden, :integer, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_canales, [:canal_nombre, :canal_factor1, :canal_factor2, :canal_factor3, :canal_orden])
  end
end
