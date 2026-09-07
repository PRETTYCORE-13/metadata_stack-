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

    # Agregado (2026-09-04, auditoría de replay desde cero): faltaba acá
    # -- la migración real generada por el BPB
    # (20260901231458_crear_pty_subtipos_transaccion_20260901231458.exs)
    # SÍ la tenía, y es parte del shape final real (verificado \d contra
    # dev). Sin esto, esa migración duplicada fallaba con "already exists"
    # en un replay desde cero antes de llegar a crear el índice.
    create unique_index(:pty_subtipos_transaccion, [:tipo_transaccion, :descripcion], name: :pty_subtipos_transaccion_unico_index)
  end
end
