defmodule MetadataApp.MetaSchema.Plantilla do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_plantillas" do
    field :nombre, :string
    field :descripcion, :string
    field :estado, :string, default: "borrador"
    field :definicion, :map,
      default: %{"tipo" => "raiz", "propiedades" => %{"filas" => 1, "columnas" => 1, "gap" => "normal"}, "hijos" => []}
    field :disponible_multi_vista, :boolean, default: false

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id
  end

  @estados ["borrador", "publicada"]

  def changeset(plantilla, attrs) do
    plantilla
    |> cast(attrs, [:meta_schema_header_id, :nombre, :descripcion, :estado, :definicion, :disponible_multi_vista])
    |> validate_required([:meta_schema_header_id, :nombre, :estado, :definicion])
    |> validate_inclusion(:estado, @estados)
  end
end
