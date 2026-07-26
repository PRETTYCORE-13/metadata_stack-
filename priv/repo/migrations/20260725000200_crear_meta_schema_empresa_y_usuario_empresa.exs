defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaEmpresaYUsuarioEmpresa do
  use Ecto.Migration

  def change do
    create table(:meta_schema_empresa) do
      add :nombre, :string, null: false

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string

      timestamps(type: :utc_datetime)
    end

    # N:N — un usuario puede tener acceso a varias empresas (tenant), y
    # elige/cambia cuál usa como "empresa activa" en su sesión (Scope).
    create table(:meta_schema_usuario_empresa) do
      add :usuario_id, references(:meta_schema_usuario, on_delete: :delete_all), null: false
      add :empresa_id, references(:meta_schema_empresa, on_delete: :delete_all), null: false

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:meta_schema_usuario_empresa, [:usuario_id, :empresa_id])
  end
end
