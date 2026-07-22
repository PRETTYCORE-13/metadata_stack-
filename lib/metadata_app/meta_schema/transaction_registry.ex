defmodule MetadataApp.MetaSchema.TransactionRegistry do
  use Ecto.Schema

  # Índice central de TRNs (ver MetadataApp.TRN) — mismo rol que
  # meta_schema_transicion_eventos: un log/índice que espeja lo que ya
  # quedó guardado como columna física en la tabla de cada catálogo
  # transaccional, para poder buscar por TRN/ULID sin UNION contra cada
  # tabla dinámica del sistema. Nunca se edita después de insertado.
  schema "meta_schema_transaction_registry" do
    field :ulid, :string
    field :trn, :string
    field :entity_id, :integer
    field :company_id, :integer

    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
