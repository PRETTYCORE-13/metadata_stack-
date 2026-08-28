defmodule MetadataApp.Repo.Migrations.CrearProductosCascadaPrueba20260819183637 do
  use Ecto.Migration

  def change do
    create table(:productos_cascada_prueba) do
      add :productos_cascada_prueba_nombre, :string, size: 150, null: false
      add :productos_cascada_prueba_categoria, references(:categorias_prueba), null: false
      add :productos_cascada_prueba_subcategoria, references(:subcategorias_prueba), null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :fecha_registro, :utc_datetime, null: true

    end

    create unique_index(:productos_cascada_prueba, [:productos_cascada_prueba_nombre, :productos_cascada_prueba_categoria, :productos_cascada_prueba_subcategoria], name: :productos_cascada_prueba_unico_index)

  end
end
