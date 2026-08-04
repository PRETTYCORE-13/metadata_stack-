defmodule MetadataApp.MetaSchema.Notificacion do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_notificacion" do
    field :mensaje, :string
    field :tipo, :string, default: "info"
    field :leida, :boolean, default: false

    belongs_to :usuario, MetadataApp.Autenticacion.Usuario

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(notificacion, attrs) do
    notificacion
    |> cast(attrs, [:usuario_id, :mensaje, :tipo, :leida])
    |> validate_required([:usuario_id, :mensaje])
    |> validate_inclusion(:tipo, ~w(info success error))
  end
end
