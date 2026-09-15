defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaConsultaEndpointJob do
  use Ecto.Migration

  # SPEC-SYS-1009202602, R39-R41 (2026-09-11) -- extracción asíncrona
  # del resultado COMPLETO de un endpoint sobre una Consulta grande.
  # Sin FK vivas a propósito, mismo criterio que meta_schema_consulta_endpoint_log
  # -- este registro tiene que sobrevivir aunque el endpoint/credencial
  # cambien de configuración después.
  def change do
    create table(:meta_schema_consulta_endpoint_job) do
      add :meta_schema_consulta_endpoint_id, :integer, null: false
      add :meta_schema_consulta_endpoint_credencial_id, :integer, null: false
      add :oban_job_id, :bigint
      add :estado, :string, null: false, default: "pendiente"
      add :archivo_resultado, :string
      add :cantidad_registros, :integer
      add :error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:meta_schema_consulta_endpoint_job, [:meta_schema_consulta_endpoint_id])
  end
end
