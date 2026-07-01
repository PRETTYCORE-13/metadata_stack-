defmodule MetadataApp.Repo.Migrations.RenombrarConfigCamposAMetaSchema do
  use Ecto.Migration

  def change do
    rename table(:config_campos), to: table(:meta_schema)

    rename index(:meta_schema, [:schema_nombre, :campo],
             name: :config_campos_schema_nombre_campo_index
           ),
           to: :meta_schema_schema_nombre_campo_index
  end
end
