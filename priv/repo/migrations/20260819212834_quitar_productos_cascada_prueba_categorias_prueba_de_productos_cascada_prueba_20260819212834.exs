defmodule MetadataApp.Repo.Migrations.QuitarProductosCascadaPruebaCategoriasPruebaDeProductosCascadaPrueba20260819212834 do
  use Ecto.Migration

  def change do
    alter table(:productos_cascada_prueba) do
      remove :productos_cascada_prueba_categorias_prueba
    end
  end
end
