defmodule MetadataApp.Repo.Migrations.CrearNdtNumberingAudits do
  use Ecto.Migration

  # Auditoría de asignaciones de folio — y a la vez el ledger de
  # idempotencia (sección 24/25 del spec NDT): en un modelo solo-next()
  # (sin reserve()/RESERVED aparte, ver moduledoc de NDT.Numbering) el
  # "registro de qué se asignó" y el "registro de auditoría" son el MISMO
  # evento, así que se consolidan acá en vez de dos tablas separadas
  # (number_allocations + numbering_audits) como sugería el spec original
  # — ver también meta_schema_transaction_registry, mismo rol
  # arquitectónico para TRN (índice central, no la única fuente de
  # verdad del contador — esa es ndt_number_ranges).
  #
  # empresa_id/branch_id/meta_schema_header_id van denormalizados (no
  # solo vía pty_ndt_configuracion_id) para que un perfil editado o dado
  # de baja después no cambie lo que un audit YA asignado dice que era
  # cierto en el momento de la asignación.
  def change do
    create table(:ndt_numbering_audits) do
      add :pty_ndt_configuracion_id, references(:pty_ndt_configuracion, on_delete: :restrict), null: false
      add :ndt_number_range_id, references(:ndt_number_ranges, on_delete: :restrict), null: false
      add :meta_schema_header_id, references(:meta_schema_header, on_delete: :restrict), null: false
      add :empresa_id, references(:meta_schema_empresa, on_delete: :restrict), null: false
      add :branch_id, references(:meta_schema_branch, on_delete: :restrict), null: true

      add :secuencia, :integer, null: false
      add :folio, :string, size: 40, null: false
      add :trn, :string, size: 23, null: true
      add :entity_id, :integer, null: true
      add :idempotency_key, :string, size: 64, null: true
      add :asignado_por_id, references(:meta_schema_usuario, on_delete: :nilify_all), null: true
      add :anulado_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:ndt_numbering_audits, [:pty_ndt_configuracion_id])
    create index(:ndt_numbering_audits, [:meta_schema_header_id])
    create index(:ndt_numbering_audits, [:trn])
    create index(:ndt_numbering_audits, [:entity_id])

    create unique_index(:ndt_numbering_audits, [:pty_ndt_configuracion_id, :folio], name: :ndt_numbering_audits_perfil_folio_unico_index)

    create unique_index(:ndt_numbering_audits, [:pty_ndt_configuracion_id, :idempotency_key],
             name: :ndt_numbering_audits_idempotencia_unica_index,
             where: "idempotency_key IS NOT NULL"
           )
  end
end
