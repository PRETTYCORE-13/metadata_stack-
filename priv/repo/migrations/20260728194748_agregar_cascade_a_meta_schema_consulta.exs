defmodule MetadataApp.Repo.Migrations.AgregarCascadeAMetaSchemaConsulta do
  use Ecto.Migration

  # La migración anterior (crear_meta_schema_consulta) creó la FK sin
  # on_delete: :delete_all por descuido — sin esto, eliminar_header/1
  # falla con violación de FK apenas un catálogo tiene una Consulta
  # asociada, en vez de arrastrarla en cascada como ya hace con
  # Estados/Transiciones/Detalles.
  def change do
    drop constraint(:meta_schema_consulta, "meta_schema_consulta_meta_schema_header_id_fkey")

    alter table(:meta_schema_consulta) do
      modify :meta_schema_header_id, references(:meta_schema_header, on_delete: :delete_all), null: false
    end
  end
end
