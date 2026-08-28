defmodule MetadataApp.MetaSchema.PlantillaImportacion do
  use Ecto.Schema
  import Ecto.Changeset

  # `definicion` (ver MetaImportacionDatos para el detalle de forma):
  #   %{
  #     "campos" => [%{"campo" => "pty_x_folio", "obligatorio" => true, "orden" => 1}, ...],
  #     "detalles" => [
  #       %{
  #         "catalogo" => "pty_x_productos",
  #         "campo_identificador_padre" => "pty_x_folio",
  #         "campos" => [%{"campo" => "...", "obligatorio" => true, "orden" => 1}, ...]
  #       },
  #       ...
  #     ]
  #   }
  # "campos" del encabezado y de cada detalle son listas EN EL ORDEN de
  # columnas del Excel — la etiqueta amigable/tipo/ejemplo de cada uno se
  # resuelven en vivo contra meta_schema_detail (nunca se copian acá,
  # así un cambio de etiqueta en Diseñador de campos se refleja solo la
  # próxima vez que se genere el Excel, sin tener que re-guardar la
  # plantilla de importación).
  schema "meta_schema_plantillas_importacion" do
    field :nombre, :string
    field :descripcion, :string
    field :estado, :string, default: "borrador"
    field :definicion, :map, default: %{"campos" => [], "detalles" => []}

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id

    # A diferencia del resto del schema (insert_guid/update_guid, el
    # convenio propio de la app) — acá SÍ hace falta una fecha real, para
    # "Última modificación" en la lista de plantillas (punto 6 del pedido).
    timestamps()
  end

  @estados ["borrador", "activa"]

  def changeset(plantilla, attrs) do
    plantilla
    |> cast(attrs, [:meta_schema_header_id, :nombre, :descripcion, :estado, :definicion])
    |> validate_required([:meta_schema_header_id, :nombre, :estado, :definicion])
    |> validate_inclusion(:estado, @estados)
  end
end
