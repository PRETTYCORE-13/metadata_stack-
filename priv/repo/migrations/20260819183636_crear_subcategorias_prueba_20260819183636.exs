defmodule MetadataApp.Repo.Migrations.CrearSubcategoriasPrueba20260819183636 do
  use Ecto.Migration

  def change do
    create table(:subcategorias_prueba) do
      add :subcategorias_prueba_nombre, :string, size: 100, null: false
      add :subcategorias_prueba_categoria, references(:categorias_prueba), null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :fecha_registro, :utc_datetime, null: true

    end

    create unique_index(:subcategorias_prueba, [:subcategorias_prueba_nombre, :subcategorias_prueba_categoria], name: :subcategorias_prueba_unico_index)

  end
end
