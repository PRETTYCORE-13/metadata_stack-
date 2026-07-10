defmodule MetadataApp.MetaSchema.Transicion do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_transiciones" do
    field :empresa_id, :integer
    field :accion, :string
    field :etiqueta, :string

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id
    belongs_to :estado_origen, MetadataApp.MetaSchema.Estado
    belongs_to :estado_destino, MetadataApp.MetaSchema.Estado

    has_many :reglas, MetadataApp.MetaSchema.TransicionRegla, foreign_key: :transicion_id
  end

  @campos [:meta_schema_header_id, :accion, :etiqueta, :estado_origen_id, :estado_destino_id, :empresa_id]
  # estado_origen_id NO es requerido: nil significa "alta" (el registro
  # todavía no existe) — ver StateEngine.dar_de_alta/4. estado_destino_id sí
  # es siempre obligatorio, toda transición tiene que aterrizar en algún lado.
  @requeridos [:meta_schema_header_id, :accion, :etiqueta, :estado_destino_id]

  def changeset(transicion, attrs) do
    transicion
    |> cast(attrs, @campos)
    |> validate_required(@requeridos)
    |> unique_constraint([:empresa_id, :meta_schema_header_id, :estado_origen_id, :accion],
      name: :meta_schema_transiciones_unico_index
    )
    |> unique_constraint([:empresa_id, :meta_schema_header_id, :accion],
      name: :meta_schema_transiciones_alta_unico_index,
      message: "ya existe una transición de alta con esta acción para este catálogo"
    )
    |> foreign_key_constraint(:meta_schema_header_id)
    |> foreign_key_constraint(:estado_origen_id)
    |> foreign_key_constraint(:estado_destino_id)
  end
end
