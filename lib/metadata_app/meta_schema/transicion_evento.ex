defmodule MetadataApp.MetaSchema.TransicionEvento do
  use Ecto.Schema
  import Ecto.Changeset

  # Solo inserción: no hay update_guid/delete_guid ni changeset de edición.
  # Un evento del historial no se modifica ni se borra una vez escrito.
  schema "meta_schema_transicion_eventos" do
    field :empresa_id, :integer
    field :registro_id, :integer
    field :accion, :string
    field :usuario_id, :integer
    field :contexto, :map, default: %{}

    field :insert_guid, :string

    belongs_to :header, MetadataApp.MetaSchema.Header, foreign_key: :meta_schema_header_id
    belongs_to :estado_origen, MetadataApp.MetaSchema.Estado
    belongs_to :estado_destino, MetadataApp.MetaSchema.Estado

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @requeridos [
    :meta_schema_header_id,
    :registro_id,
    :estado_origen_id,
    :estado_destino_id,
    :accion,
    :insert_guid
  ]

  def changeset(evento, attrs) do
    evento
    |> cast(attrs, @requeridos ++ [:empresa_id, :usuario_id, :contexto])
    |> validate_required(@requeridos)
  end
end
