defmodule MetadataApp.Repo.Migrations.RenombrarMetaSchemaAMetaContext do
  use Ecto.Migration

  def change do
    rename table(:meta_schema), to: table(:meta_context)

    rename index(:meta_context, [:schema_nombre, :campo],
             name: :meta_schema_schema_nombre_campo_index
           ),
           to: :meta_context_schema_nombre_campo_index
  end
end
