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
    # "vista" (default): plantilla interactiva de pantalla, lo de siempre.
    # "impresion": FichaLive la usa en ?imprimir=1 (ver render/1 modo
    # impresión) — nunca aparece en el selector "Vista" de pantalla, ver
    # MetaPlantillas.listar_disponibles_multi_vista/1.
    field :proposito, :string, default: "vista"

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id
  end

  @estados ["borrador", "publicada"]
  @propositos ["vista", "impresion"]

  def changeset(plantilla, attrs) do
    plantilla
    |> cast(attrs, [:meta_schema_header_id, :nombre, :descripcion, :estado, :definicion, :disponible_multi_vista, :proposito])
    |> validate_required([:meta_schema_header_id, :nombre, :estado, :definicion])
    |> validate_inclusion(:estado, @estados)
    |> validate_inclusion(:proposito, @propositos)
  end
end
