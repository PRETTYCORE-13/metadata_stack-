defmodule MetadataApp.MetaSchema.Auditoria do
  use Ecto.Schema
  import Ecto.Changeset

  # Log append-only (roadmap #6) -- nunca se edita ni se borra una fila de
  # acá, así que no tiene update_guid/delete_guid como el resto de
  # meta_schema_* ni updated_at (timestamps() de siempre). inserted_at ES
  # el dato de auditoría (y la columna de partición del schema físico) --
  # `read_after_writes` porque lo pone la DB (DEFAULT now()), no Ecto.
  @primary_key {:id, :id, autogenerate: true}
  schema "meta_schema_auditoria" do
    field :bc, :string
    field :operacion, :string
    field :guid, :string
    field :trn, :string
    field :entidad_id, :integer
    field :datos, :map
    field :usuario_id, :integer
    field :usuario_email, :string
    field :empresa_id, :integer
    field :ip, :string
    field :user_agent, :string
    field :inserted_at, :utc_datetime, read_after_writes: true
  end

  @requeridos [:bc, :operacion, :guid, :entidad_id, :datos]
  @opcionales [:trn, :usuario_id, :usuario_email, :empresa_id, :ip, :user_agent]

  def changeset(auditoria, attrs) do
    auditoria
    |> cast(attrs, @requeridos ++ @opcionales)
    |> validate_required(@requeridos)
  end
end
