defmodule MetadataApp.MetaSchema.Estado do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_estados" do
    field :empresa_id, :integer
    field :nombre, :string
    field :es_inicial, :boolean, default: false
    field :orden, :integer
    field :color, :string
    field :icono, :string

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :header, MetadataApp.MetaSchema.Header, foreign_key: :meta_schema_header_id
  end

  @requeridos [:meta_schema_header_id, :nombre, :orden]

  def changeset(estado, attrs) do
    estado
    |> cast(attrs, @requeridos ++ [:empresa_id, :es_inicial, :color, :icono])
    |> validate_required(@requeridos)
    |> unique_constraint([:meta_schema_header_id, :nombre],
      name: :meta_schema_estados_unico_index
    )
    |> unique_constraint([:meta_schema_header_id],
      name: :meta_schema_estados_un_inicial_index,
      message: "ya existe un estado inicial para este catálogo"
    )
  end
end
