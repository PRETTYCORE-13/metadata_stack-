defmodule MetadataApp.Repo.Migrations.AgregarAliasAMetaSchemaUsuario do
  use Ecto.Migration

  def change do
    alter table(:meta_schema_usuario) do
      add :alias, :string, size: 40
    end
  end
end
