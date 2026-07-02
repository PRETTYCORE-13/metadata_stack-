defmodule MetadataApp.Repo.Migrations.CrearPtyMarcaAutos do
  use Ecto.Migration

  def change do
    create table(:pty_marca_autos) do
      add :pty_marca_auto_nombre, :string, size: 20, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_marca_autos, [:pty_marca_auto_nombre])
  end
end
