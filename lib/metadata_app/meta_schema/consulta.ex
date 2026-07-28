defmodule MetadataApp.MetaSchema.Consulta do
  use Ecto.Schema
  import Ecto.Changeset

  # Un registro = la definición de un BC tipo "Consulta Ecto"
  # (schema_context_type: 3 en su Header) — sin tabla física propia, sin
  # motor de estados, sin TRN. `campos` es la lista ordenada de columnas
  # que la consulta expone (ver MetaConsultas.ejecutar/2), cada una con:
  #
  #   %{"catalogo" => nombre del catálogo dueño del campo,
  #     "campo" => nombre lógico del campo en ese catálogo,
  #     "etiqueta" => etiqueta a mostrar (si el campo no existe en
  #       meta_schema_detail de ese catálogo, se usa el nombre lógico tal
  #       cual, sin inventar una etiqueta bonita),
  #     "orden" => entero,
  #     "visible" => boolean (Get View — igual que la propiedad "visible"
  #       de un campo normal, pero acá vive en este jsonb, no en
  #       meta_schema_detail, porque un campo de consulta no es un campo
  #       real de ningún catálogo),
  #     "totalizar" => boolean (banda de totales al final de la tabla,
  #       solo aplica a columnas numéricas)}
  #
  # `joins` reservado para Fase 2 (todavía sin usar) — Fase 1 es una sola
  # tabla (`catalogo_base`).
  schema "meta_schema_consulta" do
    field :catalogo_base, :string
    field :campos, {:array, :map}, default: []
    field :joins, {:array, :map}, default: []

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id

    timestamps(type: :utc_datetime)
  end

  @requeridos [:meta_schema_header_id, :catalogo_base]

  def changeset(consulta, attrs) do
    consulta
    |> cast(attrs, @requeridos ++ [:campos, :joins])
    |> validate_required(@requeridos)
    |> unique_constraint([:meta_schema_header_id])
    |> foreign_key_constraint(:meta_schema_header_id)
  end
end
