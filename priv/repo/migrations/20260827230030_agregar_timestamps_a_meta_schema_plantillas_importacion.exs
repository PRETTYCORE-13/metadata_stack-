defmodule MetadataApp.Repo.Migrations.AgregarTimestampsAMetaSchemaPlantillasImportacion do
  use Ecto.Migration

  # Bug real (crash en vivo, KeyError :updated_at): la tabla nunca tuvo
  # timestamps() -- el resto del schema usa insert_guid/update_guid (el
  # convenio de auditoría propio de la app), pero "Última modificación"
  # de la lista de plantillas (punto 6 del pedido de Importación) necesita
  # una fecha real, no un guid opaco.
  def change do
    alter table(:meta_schema_plantillas_importacion) do
      timestamps(default: fragment("now()"))
    end
  end
end
