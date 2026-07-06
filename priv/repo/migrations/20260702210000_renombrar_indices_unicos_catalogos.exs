defmodule MetadataApp.Repo.Migrations.RenombrarIndicesUnicosCatalogos do
  use Ecto.Migration

  # Alinea los índices únicos de los catálogos generados antes de que el
  # nombre pasara a ser determinista ("<tabla>_unico_index"). Sin esto, el
  # unique_constraint/3 del changeset generado no encuentra el nombre real
  # del constraint en Postgres y una violación de unicidad revienta como
  # error 500 en vez de un 422 con mensaje de validación.
  #
  # El rename de pty_motos que existía acá se quitó: esa tabla se recreó
  # muchas veces durante pruebas (11 migraciones crear/eliminar) y las
  # versiones posteriores ya nacen con el índice determinista puesto por
  # CatalogoGenerador — el rename quedó apuntando a un índice de 3 columnas
  # que nunca vuelve a existir en una base reproducida desde cero.
  def change do
    rename index(:pty_marcas, [:pty_marca_nombre, :pty_marca_orden],
             name: :pty_marcas_pty_marca_nombre_pty_marca_orden_index
           ),
           to: :pty_marcas_unico_index
  end
end
