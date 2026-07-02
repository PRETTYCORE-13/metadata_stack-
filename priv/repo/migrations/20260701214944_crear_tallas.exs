defmodule MetadataApp.Repo.Migrations.CrearTallas do
  use Ecto.Migration

  def change do
    create table(:tallas) do
      add :nombre_talla, :string, size: 10, null: false
      add :segmento_talla, :string, size: 15, null: false
      add :tipo_talla, :string, size: 15, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:tallas, [:nombre_talla, :segmento_talla, :tipo_talla])
  end
end
