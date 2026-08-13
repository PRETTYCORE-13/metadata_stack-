defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaAccionLog do
  use Ecto.Migration

  def change do
    # Fase 8 de "Integraciones" (2026-08-07) — log INMUTABLE de cada
    # ejecución real (botón humano o regla post), para observabilidad ("¿el
    # botón que configuré de verdad funciona cuando alguien lo clickea?").
    # Sin updated_at: nunca se edita una fila ya escrita. nilify_all en
    # accion_id/credencial_id/usuario_id -- borrar la acción, la credencial
    # o el usuario no debe borrar el historial de lo que pasó.
    create table(:meta_schema_accion_log) do
      add :accion_id, references(:meta_schema_accion_externa, on_delete: :nilify_all)
      add :credencial_id, references(:meta_schema_credencial, on_delete: :nilify_all)
      add :usuario_id, references(:meta_schema_usuario, on_delete: :nilify_all)

      add :accion_nombre, :string, null: false
      add :catalogo, :string
      add :registro_id, :integer
      add :origen, :string, null: false
      add :ok, :boolean, null: false
      add :status_http, :integer
      add :error, :text
      add :duracion_ms, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:meta_schema_accion_log, [:accion_id])
    create index(:meta_schema_accion_log, [:credencial_id])
    create index(:meta_schema_accion_log, [:inserted_at])
  end
end
