defmodule MetadataApp.Repo.Migrations.AgregarColumnasAlcanceVisiblesAHeader do
  use Ecto.Migration

  def change do
    alter table(:meta_schema_header) do
      add :mostrar_empresa_en_tabla, :boolean, null: false, default: true
      add :mostrar_branch_en_tabla, :boolean, null: false, default: true
      add :mostrar_inventory_location_en_tabla, :boolean, null: false, default: true
      add :mostrar_sales_unit_en_tabla, :boolean, null: false, default: true
    end
  end
end
