defmodule MetadataApp.NDT.NumberingAudit do
  use Ecto.Schema
  import Ecto.Changeset

  # Ledger de asignaciones de folio — a la vez auditoría (sección 25 del
  # spec NDT) y registro de idempotencia (sección 24): en un modelo
  # solo-next() ambos son el mismo evento. Nunca se edita después de
  # insertado salvo `anulado_at` (ver NDT.Numbering.anular/1) — no hay
  # updated_at a propósito, mismo criterio que TransactionRegistry.
  schema "ndt_numbering_audits" do
    belongs_to :perfil, MetadataApp.MetaBusinessProcess.Catalogos.PtyNdtConfiguracion, foreign_key: :pty_ndt_configuracion_id
    belongs_to :number_range, MetadataApp.NDT.NumberRange, foreign_key: :ndt_number_range_id
    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id
    belongs_to :empresa, MetadataApp.Autenticacion.Empresa
    belongs_to :branch, MetadataApp.Autenticacion.Branch

    field :secuencia, :integer
    field :folio, :string
    field :trn, :string
    field :entity_id, :integer
    field :idempotency_key, :string
    field :asignado_por_id, :integer
    field :anulado_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @requeridos [
    :pty_ndt_configuracion_id,
    :ndt_number_range_id,
    :meta_schema_header_id,
    :empresa_id,
    :secuencia,
    :folio
  ]
  @opcionales [:branch_id, :trn, :entity_id, :idempotency_key, :asignado_por_id]

  def changeset(audit, attrs) do
    audit
    |> cast(attrs, @requeridos ++ @opcionales)
    |> validate_required(@requeridos)
    |> unique_constraint([:pty_ndt_configuracion_id, :folio], name: :ndt_numbering_audits_perfil_folio_unico_index)
    |> unique_constraint([:pty_ndt_configuracion_id, :idempotency_key], name: :ndt_numbering_audits_idempotencia_unica_index)
  end

  def changeset_anular(audit, anulado_at \\ DateTime.utc_now()) do
    change(audit, anulado_at: anulado_at)
  end
end
