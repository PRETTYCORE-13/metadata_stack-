defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaReglasCodigo do
  use Ecto.Migration

  # Rediseño de reglas PRE/POST (2026-07-21): un catálogo tiene a lo sumo UN
  # código pre y UN código post — el `case` por acción vive adentro del
  # código mismo, no en filas de meta_schema_transicion_reglas (que deja de
  # leerse en ejecución, ver MetaStateEngine.Reglas). "bloqueado_por"/
  # "bloqueado_en" son un candado LIVIANO (nombre auto-declarado, no hay
  # login real en la app todavía) para evitar que dos personas editen el
  # mismo código a la vez — no es una garantía de seguridad, es una
  # protección contra choques accidentales.
  def change do
    create table(:meta_schema_reglas_codigo) do
      add :meta_schema_header_id, references(:meta_schema_header, on_delete: :delete_all), null: false
      add :tipo, :string, size: 10, null: false
      add :codigo_fuente, :text, null: false
      add :editado_por, :string, size: 100, null: true
      add :bloqueado_por, :string, size: 100, null: true
      add :bloqueado_en, :utc_datetime_usec, null: true

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:meta_schema_reglas_codigo, [:meta_schema_header_id, :tipo],
             name: :meta_schema_reglas_codigo_unico_index
           )
  end
end
