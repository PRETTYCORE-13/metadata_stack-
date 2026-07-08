defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaTransicionEventos do
  use Ecto.Migration

  # Historial inmutable: sin update_guid/delete_guid (no aplica soft-delete,
  # nunca se borra ni se edita un evento ya escrito). Lleva inserted_at real
  # porque el orden temporal es parte del valor del historial — a diferencia
  # del resto de las tablas de este proyecto, que solo auditan con GUIDs.
  # FKs con on_delete: :restrict (no cascade/nilify): un evento ya escrito no
  # puede perder su referencia a qué header/estado fue — si algún día se hace
  # un DELETE físico real (hoy todo es soft-delete), que falle antes que
  # corromper el historial en silencio.
  def change do
    create table(:meta_schema_transicion_eventos) do
      add :empresa_id, :integer, null: true

      add :meta_schema_header_id, references(:meta_schema_header, on_delete: :restrict),
        null: false

      add :registro_id, :integer, null: false
      add :estado_origen_id, references(:meta_schema_estados, on_delete: :restrict), null: false
      add :estado_destino_id, references(:meta_schema_estados, on_delete: :restrict), null: false
      add :accion, :string, size: 100, null: false
      add :usuario_id, :integer, null: true
      add :contexto, :map, null: false, default: %{}

      add :insert_guid, :string, size: 32, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:meta_schema_transicion_eventos, [:meta_schema_header_id, :registro_id],
             name: :meta_schema_transicion_eventos_header_registro_index
           )
  end
end
