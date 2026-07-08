defmodule MetadataApp.MetaSchema.Header do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_header" do
    field :schema_context_name, :string
    field :schema_context_label, :string
    field :schema_context_type, :integer, default: 1
    field :schema_context_nav, :string
    field :schema_visible, :boolean
    field :schema_set_permissions, :map
    field :schema_profiles, :map

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    has_many :detalles, MetadataApp.MetaSchema.Detail, foreign_key: :meta_schema_header_id
    has_many :estados, MetadataApp.MetaSchema.Estado, foreign_key: :meta_schema_header_id
    has_many :transiciones, MetadataApp.MetaSchema.Transicion, foreign_key: :meta_schema_header_id
  end

  @requeridos [
    :schema_context_name,
    :schema_context_label,
    :schema_context_type,
    :schema_context_nav,
    :schema_visible
  ]

  def changeset(header, attrs) do
    header
    |> cast(attrs, @requeridos ++ [:schema_set_permissions, :schema_profiles])
    |> validate_required(@requeridos)
    |> unique_constraint(:schema_context_name)
  end
end
