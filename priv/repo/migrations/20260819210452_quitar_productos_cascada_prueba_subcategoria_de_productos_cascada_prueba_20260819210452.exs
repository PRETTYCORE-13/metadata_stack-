defmodule MetadataApp.Repo.Migrations.QuitarProductosCascadaPruebaSubcategoriaDeProductosCascadaPrueba20260819210452 do
  use Ecto.Migration

  def change do
    alter table(:productos_cascada_prueba) do
      remove :productos_cascada_prueba_subcategoria
    end
  end
end
