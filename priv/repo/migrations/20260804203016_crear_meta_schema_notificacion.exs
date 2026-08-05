defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaNotificacion do
  use Ecto.Migration

  def change do
    create table(:meta_schema_notificacion) do
      add :usuario_id, references(:meta_schema_usuario, on_delete: :delete_all), null: false
      add :mensaje, :string, null: false
      add :tipo, :string, null: false, default: "info"
      add :leida, :boolean, null: false, default: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:meta_schema_notificacion, [:usuario_id, :inserted_at])
  end
end
