defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaTransiciones do
  use Ecto.Migration

  def change do
    create table(:meta_schema_transiciones) do
      add :empresa_id, :integer, null: true

      add :meta_schema_header_id, references(:meta_schema_header, on_delete: :delete_all),
        null: false

      add :accion, :string, size: 100, null: false
      add :etiqueta, :string, size: 100, null: false
      add :estado_origen_id, references(:meta_schema_estados, on_delete: :delete_all), null: false

      add :estado_destino_id, references(:meta_schema_estados, on_delete: :delete_all),
        null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    # (catalogo, estado_origen, accion) único por empresa — spec 3.2.
    create unique_index(
             :meta_schema_transiciones,
             [:empresa_id, :meta_schema_header_id, :estado_origen_id, :accion],
             name: :meta_schema_transiciones_unico_index
           )

    create index(:meta_schema_transiciones, [:estado_destino_id])
  end
end
