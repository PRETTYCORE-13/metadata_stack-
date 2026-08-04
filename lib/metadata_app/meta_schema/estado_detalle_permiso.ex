defmodule MetadataApp.MetaSchema.EstadoDetallePermiso do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_estado_detalle_permiso" do
    field :empresa_id, :integer
    field :permite_insertar, :boolean, default: false
    field :permite_actualizar, :boolean, default: false
    field :permite_borrar, :boolean, default: false

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :estado, MetadataApp.MetaSchema.Estado, foreign_key: :meta_schema_estado_id

    belongs_to :header_detalle, MetadataApp.BusinessProcessBuilder.MetaSchema.Header,
      foreign_key: :meta_schema_header_detalle_id
  end

  @requeridos [:meta_schema_estado_id, :meta_schema_header_detalle_id]

  def changeset(permiso, attrs) do
    permiso
    |> cast(attrs, @requeridos ++ [:empresa_id, :permite_insertar, :permite_actualizar, :permite_borrar])
    |> validate_required(@requeridos)
    |> unique_constraint([:meta_schema_estado_id, :meta_schema_header_detalle_id],
      name: :meta_estado_detalle_permiso_unico_index
    )
    |> foreign_key_constraint(:meta_schema_estado_id)
    |> foreign_key_constraint(:meta_schema_header_detalle_id)
  end
end
