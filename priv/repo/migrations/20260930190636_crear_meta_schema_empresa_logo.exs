defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaEmpresaLogo do
  use Ecto.Migration

  def change do
    # Tabla aparte (no columna bytea en meta_schema_empresa): la Empresa se
    # carga en cada request al hidratar el scope, y el binario no debe viajar
    # con ella. Ver SPEC-SYS-3009202601 D1.
    create table(:meta_schema_empresa_logo) do
      add :empresa_id, references(:meta_schema_empresa, on_delete: :delete_all), null: false
      add :contenido, :binary, null: false
      add :content_type, :string, null: false
      add :ancho, :integer, null: false
      add :alto, :integer, null: false
      add :tamano_bytes, :integer, null: false
      add :hash, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:meta_schema_empresa_logo, [:empresa_id])

    alter table(:meta_schema_empresa) do
      add :logo_version, :string
    end
  end
end
