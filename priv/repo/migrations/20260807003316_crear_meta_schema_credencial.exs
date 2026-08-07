defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaCredencial do
  use Ecto.Migration

  def change do
    # api_key es :binary (no :string) -- Cloak.Ecto.Binary guarda el
    # ciphertext ahí, nunca texto plano en ninguna columna. Ver
    # MetadataApp.Encriptado/MetadataApp.Vault.
    create table(:meta_schema_credencial) do
      add :nombre, :string, null: false
      add :sistema_externo, :string
      add :api_key, :binary, null: false
      add :base_url, :string

      add :ultima_ejecucion_en, :utc_datetime
      add :ultimo_error, :text

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string

      timestamps(type: :utc_datetime)
    end

    create index(:meta_schema_credencial, [:delete_guid])
  end
end
