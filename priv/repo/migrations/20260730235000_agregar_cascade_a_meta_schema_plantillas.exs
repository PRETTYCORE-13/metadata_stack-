defmodule MetadataApp.Repo.Migrations.AgregarCascadeAMetaSchemaPlantillas do
  use Ecto.Migration

  # Mismo descuido (y mismo arreglo) que 20260728194748_agregar_cascade_a_meta_schema_consulta:
  # la migración original (crear_meta_schema_plantillas) creó la FK sin
  # on_delete: :delete_all — sin esto, eliminar_header/1 fallaba con
  # violación de FK apenas un catálogo tenía una Plantilla asociada (que
  # es TODO catálogo, ya que CatalogoGenerador.generar/1 le crea una
  # default automática a cualquiera nuevo), en vez de arrastrarla en
  # cascada como ya hace con Estados/Transiciones/Detalles/Consulta.
  def change do
    drop constraint(:meta_schema_plantillas, "meta_schema_plantillas_meta_schema_header_id_fkey")

    alter table(:meta_schema_plantillas) do
      modify :meta_schema_header_id, references(:meta_schema_header, on_delete: :delete_all), null: false
    end
  end
end
