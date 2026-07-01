defmodule MetadataApp.Repo.Migrations.CrearMarcas do
  use Ecto.Migration

  def change do
    create table(:marcas) do
      add :marca_descrip, :string, size: 25, null: false

      add :insert_guid,   :string, size: 32, null: false
      add :update_guid,   :string, size: 32, null: true
      add :delete_guid,   :string, size: 32, null: true
    end

    create unique_index(:marcas, [:marca_descrip])
  end
end
