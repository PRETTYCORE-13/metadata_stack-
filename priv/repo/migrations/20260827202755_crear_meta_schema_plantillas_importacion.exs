defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaPlantillasImportacion do
  use Ecto.Migration

  # Módulo de Importación de Datos (Fase 1) — una plantilla de importación
  # describe qué columnas ofrece la plantilla Excel descargable de un
  # catálogo y cómo mapearlas de vuelta a campos reales al subir el
  # archivo lleno (ver MetaImportacionDatos). Mismo patrón de tabla que
  # meta_schema_plantillas (plantillas de impresión/vista), con una
  # diferencia a propósito: acá NO hay índice único de "una activa por
  # catálogo" — varias plantillas pueden convivir activas a la vez (ej.
  # "Importación básica" y "Importación completa" del mismo catálogo).
  def change do
    create table(:meta_schema_plantillas_importacion) do
      add :meta_schema_header_id, references(:meta_schema_header), null: false
      add :nombre, :string, size: 100, null: false
      add :descripcion, :string, size: 255
      add :estado, :string, size: 20, null: false, default: "borrador"
      add :definicion, :map, null: false, default: %{"campos" => [], "detalles" => []}

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create index(:meta_schema_plantillas_importacion, [:meta_schema_header_id])
  end
end
