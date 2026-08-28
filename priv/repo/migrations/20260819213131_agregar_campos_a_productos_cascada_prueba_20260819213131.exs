defmodule MetadataApp.Repo.Migrations.AgregarProductosCascadaPruebaCategoriasPruebaAProductosCascadaPrueba20260819213131 do
  use Ecto.Migration

  def change do
    alter table(:productos_cascada_prueba) do
      add :productos_cascada_prueba_categorias_prueba, references(:categorias_prueba), null: true
    end
  end
end
