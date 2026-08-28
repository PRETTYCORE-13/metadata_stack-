defmodule MetadataApp.Repo.Migrations.AgregarProductosCascadaPruebaSubcategoriasPruebaAProductosCascadaPrueba20260819194802 do
  use Ecto.Migration

  def change do
    alter table(:productos_cascada_prueba) do
      add :productos_cascada_prueba_subcategorias_prueba, references(:subcategorias_prueba), null: true
    end
  end
end
