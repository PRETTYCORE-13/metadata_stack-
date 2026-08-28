defmodule MetadataApp.Repo.Migrations.CrearCategoriasPrueba20260819183635 do
  use Ecto.Migration

  def change do
    create table(:categorias_prueba) do
      add :categorias_prueba_nombre, :string, size: 100, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :fecha_registro, :utc_datetime, null: true

    end

    create unique_index(:categorias_prueba, [:categorias_prueba_nombre], name: :categorias_prueba_unico_index)

  end
end
