defmodule MetadataApp.Repo.Migrations.AgregarEncabezadoIdAMetaSchemaHeader do
  use Ecto.Migration

  def change do
    alter table(:meta_schema_header) do
      add :schema_encabezado_id, references(:meta_schema_header), null: true
    end
  end
end
