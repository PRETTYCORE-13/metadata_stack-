defmodule MetadataApp.IdentificadoresTransaccionales.FolioHistorial do
  use Ecto.Schema
  import Ecto.Changeset

  # Ledger append-only — ver moduledoc de
  # MetadataApp.IdentificadoresTransaccionales y design.md §2.2. Nunca
  # se edita después de insertado (sin updated_at, sin changeset de
  # update).
  schema "folio_historial" do
    belongs_to :perfil, MetadataApp.MetaBusinessProcess.Catalogos.PtyFolioPerfiles, foreign_key: :pty_folio_perfiles_id
    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id
    belongs_to :branch, MetadataApp.Autenticacion.Branch

    field :subtipo_transaccion_id, :integer
    field :serie, :string
    field :folio, :integer
    field :entity_id, :integer
    field :trn, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @requeridos [:pty_folio_perfiles_id, :meta_schema_header_id, :serie, :folio, :entity_id]
  @opcionales [:subtipo_transaccion_id, :branch_id, :trn]

  def changeset(historial, attrs) do
    historial
    |> cast(attrs, @requeridos ++ @opcionales)
    |> validate_required(@requeridos)
    |> unique_constraint([:pty_folio_perfiles_id, :folio], name: :folio_historial_perfil_folio_unico_index)
  end
end
