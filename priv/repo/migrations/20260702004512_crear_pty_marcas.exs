defmodule MetadataApp.Repo.Migrations.CrearPtyMarcas do
  use Ecto.Migration

  def change do
    create table(:pty_marcas) do
      add :pty_marca_nombre, :string, size: 15, null: false
      add :pty_marca_orden, :integer, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_marcas, [:pty_marca_nombre, :pty_marca_orden])
  end
end
