defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaHeaderDetail do
  use Ecto.Migration

  # Reemplazo del motor de metadata: meta_context (tabla plana) y catalogos
  # (índice tabla -> módulo) se retiran a favor de un maestro-detalle.
  # schema_context_name cubre ahora los dos roles que antes cumplían
  # schema_nombre y tabla por separado: identifica el catálogo y es el
  # nombre físico de la tabla de Postgres.
  def change do
    drop_if_exists table(:pty_motos)
    drop_if_exists table(:catalogos)
    drop_if_exists table(:meta_context)

    create table(:meta_schema_header) do
      add :schema_context_name, :string, size: 100, null: false
      add :schema_context_label, :string, size: 100, null: false
      add :schema_context_type, :integer, null: false, default: 1
      add :schema_context_nav, :string, size: 255, null: false
      add :schema_visible, :boolean, null: false
      add :schema_set_permissions, :map, null: true
      add :schema_profiles, :map, null: true

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:meta_schema_header, [:schema_context_name])

    create table(:meta_schema_detail) do
      add :meta_schema_header_id, references(:meta_schema_header, on_delete: :delete_all), null: false
      add :schema_context_field, :string, size: 100, null: false
      add :schema_context_properties, :map, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:meta_schema_detail, [:meta_schema_header_id, :schema_context_field],
             name: :meta_schema_detail_unico_index
           )
  end
end
