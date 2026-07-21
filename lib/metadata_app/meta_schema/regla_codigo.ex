defmodule MetadataApp.MetaSchema.ReglaCodigo do
  use Ecto.Schema
  import Ecto.Changeset

  @tipos ~w(pre post)

  schema "meta_schema_reglas_codigo" do
    field :tipo, :string
    field :codigo_fuente, :string
    field :editado_por, :string

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id

    timestamps(type: :utc_datetime_usec)
  end

  @requeridos [:meta_schema_header_id, :tipo, :codigo_fuente]

  def changeset(regla_codigo, attrs) do
    regla_codigo
    |> cast(attrs, @requeridos ++ [:editado_por])
    |> validate_required(@requeridos)
    |> validate_inclusion(:tipo, @tipos)
    |> foreign_key_constraint(:meta_schema_header_id)
    |> unique_constraint([:meta_schema_header_id, :tipo], name: :meta_schema_reglas_codigo_unico_index)
  end
end
