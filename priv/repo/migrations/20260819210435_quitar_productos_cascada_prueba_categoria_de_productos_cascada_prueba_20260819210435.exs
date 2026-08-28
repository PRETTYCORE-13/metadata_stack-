defmodule MetadataApp.Repo.Migrations.QuitarProductosCascadaPruebaCategoriaDeProductosCascadaPrueba20260819210435 do
  use Ecto.Migration

  def change do
    alter table(:productos_cascada_prueba) do
      remove :productos_cascada_prueba_categoria
    end
  end
end
