defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaConsultaEndpoint do
  use Ecto.Migration

  def change do
    create table(:meta_schema_consulta_endpoint) do
      add :meta_schema_consulta_id, references(:meta_schema_consulta, on_delete: :delete_all), null: false
      add :nombre, :string, null: false
      add :metodo, :string, null: false
      add :ruta, :string, null: false
      add :descripcion, :string

      # [%{"campo" => "<catalogo>__<campo>", "obligatorio" => bool}, ...]
      add :parametros, :map, null: false, default: fragment("'[]'::jsonb")

      add :estado, :string, null: false, default: "borrador"
      add :empresa_id, references(:meta_schema_empresa, on_delete: :restrict), null: false

      # SHA-256 en hex de la API key completa -- solo sirve para
      # verificar (secure_compare), nunca para recuperar la key
      # (R25 -- ver design.md §1). nil hasta la primera publicación.
      add :api_key_hash, :string
      # Últimos 4 caracteres de la key en claro, SOLO para mostrar la
      # forma enmascarada -- no alcanza para autenticarse.
      add :api_key_sufijo, :string, size: 4

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:meta_schema_consulta_endpoint, [:meta_schema_consulta_id])

    create unique_index(:meta_schema_consulta_endpoint, [:metodo, :ruta],
             where: "delete_guid IS NULL",
             name: :meta_schema_consulta_endpoint_metodo_ruta_index
           )
  end
end
