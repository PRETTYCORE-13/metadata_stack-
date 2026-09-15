defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaConsultaEndpointLog do
  use Ecto.Migration

  def change do
    create table(:meta_schema_consulta_endpoint_log) do
      # Sin FK viva a propósito -- el log sobrevive aunque el endpoint
      # se borre o cambie de configuración después (design.md §1.1).
      add :meta_schema_consulta_endpoint_id, :integer, null: false
      add :fecha_hora, :utc_datetime_usec, null: false
      add :empresa_id, :integer, null: false
      add :ip, :string
      add :metodo, :string, null: false
      add :resultado_http, :integer, null: false
      add :duracion_ms, :integer, null: false
      add :cantidad_registros, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:meta_schema_consulta_endpoint_log, [:meta_schema_consulta_endpoint_id])
  end
end
