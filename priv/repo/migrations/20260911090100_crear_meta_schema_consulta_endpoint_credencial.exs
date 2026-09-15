defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaConsultaEndpointCredencial do
  use Ecto.Migration

  def change do
    create table(:meta_schema_consulta_endpoint_credencial) do
      add :meta_schema_consulta_endpoint_id, references(:meta_schema_consulta_endpoint, on_delete: :delete_all), null: false
      add :nombre, :string, null: false

      add :api_key_hash, :string, null: false
      add :api_key_sufijo, :string, size: 4, null: false

      # [<clave_campo>, ...] -- subconjunto de los campos VISIBLES del
      # endpoint que esta credencial puede recibir (R42-R44).
      add :campos_permitidos, {:array, :string}, null: false, default: []

      add :estado, :string, null: false, default: "activa"

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      timestamps(type: :utc_datetime)
    end

    create index(:meta_schema_consulta_endpoint_credencial, [:meta_schema_consulta_endpoint_id])
    create unique_index(:meta_schema_consulta_endpoint_credencial, [:api_key_hash])
  end
end
