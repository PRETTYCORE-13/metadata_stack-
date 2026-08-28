defmodule MetadataApp.Repo.Migrations.AgregarProductosCascadaPruebaSubcategoriaAProductosCascadaPrueba20260820165157 do
  use Ecto.Migration

  def change do
    alter table(:productos_cascada_prueba) do
      add :productos_cascada_prueba_subcategoria, references(:subcategorias_prueba), null: true
    end
  end
end
