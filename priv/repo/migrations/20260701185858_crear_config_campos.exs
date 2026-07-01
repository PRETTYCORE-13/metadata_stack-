defmodule MetadataApp.Repo.Migrations.CrearConfigCampos do
  use Ecto.Migration

  def change do
    create table(:config_campos) do
      add :schema_nombre, :string, null: false
      add :campo,         :string, null: false
      add :propiedades,   :map,    null: false

      add :insert_guid,   :string, size: 32, null: false
      add :update_guid,   :string, size: 32, null: true
      add :delete_guid,   :string, size: 32, null: true
    end

    create unique_index(:config_campos, [:schema_nombre, :campo])
  end
end
