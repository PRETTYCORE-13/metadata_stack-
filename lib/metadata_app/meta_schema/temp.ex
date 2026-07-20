defmodule MetadataApp.MetaSchema.Temp do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_temp" do
    field :nombre, :string
    field :contenido_json, :map

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime_usec)
  end

  @requeridos [:nombre, :contenido_json]

  def changeset(temp, attrs) do
    temp
    |> cast(attrs, @requeridos)
    |> validate_required(@requeridos)
  end
end
