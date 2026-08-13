defmodule MetadataApp.Repo.Migrations.AgregarDefaultsAUsuarioBranch do
  use Ecto.Migration

  def change do
    alter table(:meta_schema_usuario_branch) do
      add :inventory_default_id, references(:meta_schema_inventory_location, on_delete: :nilify_all)
      add :sales_unit_default_id, references(:meta_schema_sales_unit, on_delete: :nilify_all)
    end
  end
end
