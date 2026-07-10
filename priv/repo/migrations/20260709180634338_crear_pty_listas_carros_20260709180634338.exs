defmodule MetadataApp.Repo.Migrations.CrearPtyListasCarros20260709180634338 do
  use Ecto.Migration

  def change do
    create table(:pty_listas_carros) do
      add :nombre, :string, size: 255, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_listas_carros, [:nombre], name: :pty_listas_carros_unico_index)
  end
end
