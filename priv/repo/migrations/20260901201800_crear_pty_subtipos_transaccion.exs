defmodule MetadataApp.Repo.Migrations.CrearPtySubtiposTransaccion do
  use Ecto.Migration

  # SPEC-SYS-0109202601 (Administrador de Folios), Grupo F (tasks.md
  # tarea 25) -- tabla física de `pty_subtipos_transaccion`, nunca
  # comiteada por el mismo motivo que `pty_folio_perfiles` (ver
  # `20260901201822_crear_pty_folio_perfiles_20260901201822.exs`).
  # Timestamp ANTES que esa migración a propósito: `pty_folio_perfiles`
  # tiene una FK dura (`pty_folio_perfiles_subtipos_transaccion`) contra
  # esta tabla, tiene que existir primero.
  def change do
    create table(:pty_subtipos_transaccion) do
      add :tipo_transaccion, references(:meta_schema_header), null: false
      add :descripcion, :string, size: 255, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

      add :fecha_registro, :utc_datetime, null: true
    end
  end
end
