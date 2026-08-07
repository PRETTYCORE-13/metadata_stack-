defmodule MetadataApp.Integraciones.AccionExterna do
  use Ecto.Schema
  import Ecto.Changeset

  @metodos ~w(GET POST PUT PATCH DELETE)

  schema "meta_schema_accion_externa" do
    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id
    belongs_to :credencial, MetadataApp.Integraciones.Credencial

    field :nombre, :string
    field :etiqueta, :string
    field :metodo, :string
    # Con {campo} como placeholder -- ver MetadataApp.BusinessProcessBuilder.
    # CatalogoGenerico.sustituir_variables/2, reusado tal cual por
    # Integraciones.ejecutar/2 (Fase 4).
    field :url_template, :string
    field :headers_template, :map, default: %{}
    field :body_template, :string
    field :confirmar_antes, :boolean, default: false
    field :orden, :integer, default: 0

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime)
  end

  def metodos, do: @metodos

  def changeset(accion, attrs) do
    accion
    |> cast(attrs, [
      :meta_schema_header_id,
      :credencial_id,
      :nombre,
      :etiqueta,
      :metodo,
      :url_template,
      :headers_template,
      :body_template,
      :confirmar_antes,
      :orden
    ])
    |> validate_required([:credencial_id, :nombre, :metodo, :url_template])
    |> validate_inclusion(:metodo, @metodos)
    |> foreign_key_constraint(:credencial_id)
    |> foreign_key_constraint(:meta_schema_header_id)
  end
end
