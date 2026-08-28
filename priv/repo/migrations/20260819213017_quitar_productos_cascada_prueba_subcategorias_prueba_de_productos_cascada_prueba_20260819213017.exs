defmodule MetadataApp.Repo.Migrations.QuitarProductosCascadaPruebaSubcategoriasPruebaDeProductosCascadaPrueba20260819213017 do
  use Ecto.Migration

  def change do
    alter table(:productos_cascada_prueba) do
      remove :productos_cascada_prueba_subcategorias_prueba
    end
  end
end
