defmodule MetadataApp.Repo.Migrations.CrearFolioHistorial do
  use Ecto.Migration

  # SPEC-SYS-0109202601 (Administrador de Folios, design.md §2.2) —
  # ledger append-only de asignaciones: una fila por cada folio
  # asignado alguna vez, para siempre. Nunca se actualiza ni se borra
  # (sin updated_at, mismo criterio que meta_schema_transaction_registry
  # para TRN). Se inserta en el MISMO paso atómico que folio+TRN
  # (design.md §1.2), por eso guarda `trn` directo -- ya está disponible
  # en ese momento.
  #
  # No es un BC (sin Ficha/Get View) -- mismo rol que
  # meta_schema_transaction_registry ya tiene para TRN: índice/ledger
  # interno del motor, no un catálogo de negocio.
  def change do
    create table(:folio_historial) do
      add :pty_folio_perfiles_id, references(:pty_folio_perfiles, on_delete: :restrict), null: false
      add :meta_schema_header_id, references(:meta_schema_header, on_delete: :restrict), null: false
      add :subtipo_transaccion_id, :integer, null: true
      add :branch_id, references(:meta_schema_branch, on_delete: :restrict), null: true

      add :serie, :string, size: 4, null: false
      add :folio, :integer, null: false
      add :entity_id, :integer, null: false
      add :trn, :string, size: 23, null: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:folio_historial, [:pty_folio_perfiles_id])
    create index(:folio_historial, [:meta_schema_header_id])
    create index(:folio_historial, [:entity_id])
    create index(:folio_historial, [:trn])
    create unique_index(:folio_historial, [:pty_folio_perfiles_id, :folio], name: :folio_historial_perfil_folio_unico_index)
  end
end
