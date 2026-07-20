defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaTemp do
  use Ecto.Migration

  # Borradores del wizard "Nuevo catálogo" (BcNuevoCompletoLive): guarda
  # Contexto+Campos+Estados+Transiciones+Reglas tal cual vive en los assigns
  # mientras el usuario todavía lo está diseñando, sin tocar meta_schema_header
  # ni generar ninguna tabla física — eso sigue pasando solo al confirmar
  # "Crear Business Process". updated_at real (no solo GUIDs) porque acá sí
  # importa mostrar "editado hace X" al listar borradores.
  def change do
    create table(:meta_schema_temp) do
      add :nombre, :string, size: 100, null: false
      add :contenido_json, :map, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      timestamps(type: :utc_datetime_usec)
    end
  end
end
