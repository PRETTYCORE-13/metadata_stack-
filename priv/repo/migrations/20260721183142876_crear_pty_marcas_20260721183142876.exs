defmodule MetadataApp.Repo.Migrations.CrearPtyMarcas20260721183142876 do
  use Ecto.Migration

  def change do
    create table(:pty_marcas) do
      add :pty_marcas_nombre, :string, size: 15, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_marcas, [:pty_marcas_nombre], name: :pty_marcas_unico_index)
  end
end
