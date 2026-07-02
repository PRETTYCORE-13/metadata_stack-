defmodule MetadataApp.Repo.Migrations.CrearColores do
  use Ecto.Migration

  def change do
    create table(:colores) do
      add :nombre_color, :string, size: 25, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:colores, [:nombre_color])
  end
end
