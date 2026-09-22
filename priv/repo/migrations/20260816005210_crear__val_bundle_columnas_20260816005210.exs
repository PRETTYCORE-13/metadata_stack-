defmodule MetadataApp.Repo.Migrations.CrearValBundleColumnas20260816005210 do
  use Ecto.Migration

  def change do
    create table(:_val_bundle_columnas) do
      add :nombre, :string, size: 255, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :fecha_registro, :utc_datetime, null: true

    end

    create unique_index(:_val_bundle_columnas, [:nombre], name: :_val_bundle_columnas_unico_index)

  end
end
