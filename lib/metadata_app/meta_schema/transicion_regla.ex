defmodule MetadataApp.MetaSchema.TransicionRegla do
  use Ecto.Schema
  import Ecto.Changeset

  @tipos ~w(pre post)

  schema "meta_schema_transicion_reglas" do
    field :tipo, :string
    field :regla, :string
    field :params, :map, default: %{}
    field :orden, :integer, default: 0
    field :transaccional, :boolean, default: true

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :transicion, MetadataApp.MetaSchema.Transicion
  end

  @requeridos [:transicion_id, :tipo, :regla]

  def changeset(regla, attrs) do
    regla
    |> cast(attrs, @requeridos ++ [:params, :orden, :transaccional])
    |> validate_required(@requeridos)
    |> validate_inclusion(:tipo, @tipos)
    |> foreign_key_constraint(:transicion_id)
  end
end
