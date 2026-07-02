defmodule MetadataApp.Repo.Migrations.RenombrarIndicesUnicosCatalogos do
  use Ecto.Migration

  # Alinea los índices únicos de los catálogos generados antes de que el
  # nombre pasara a ser determinista ("<tabla>_unico_index"). Sin esto, el
  # unique_constraint/3 del changeset generado no encuentra el nombre real
  # del constraint en Postgres y una violación de unicidad revienta como
  # error 500 en vez de un 422 con mensaje de validación.
  def change do
    rename index(:pty_marcas, [:pty_marca_nombre, :pty_marca_orden],
             name: :pty_marcas_pty_marca_nombre_pty_marca_orden_index
           ),
           to: :pty_marcas_unico_index

    rename index(:pty_motos, [:pty_moto_nombre, :pty_moto_tipo, :pty_moto_licencia],
             name: :pty_motos_pty_moto_nombre_pty_moto_tipo_pty_moto_licencia_index
           ),
           to: :pty_motos_unico_index
  end
end
