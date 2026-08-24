defmodule MetadataApp.Repo.Migrations.EliminarMetaSchemaTemp do
  use Ecto.Migration

  # Respaldaba "Guardar borrador" del wizard Nuevo BC (BorradoresMotor,
  # MetaSchema.Temp) -- función retirada por no agregar valor (ver commit
  # d8bc6b9). Sin código que la use en todo el proyecto.
  def change do
    drop table(:meta_schema_temp)
  end
end
