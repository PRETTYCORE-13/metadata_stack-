defmodule MetadataApp.BusinessProcessBuilder.MetaSchema.Detail do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_detail" do
    field :schema_context_field, :string
    field :schema_context_properties, :map

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    belongs_to :header, MetadataApp.BusinessProcessBuilder.MetaSchema.Header, foreign_key: :meta_schema_header_id
  end

  def changeset(detail, attrs) do
    detail
    |> cast(attrs, [:meta_schema_header_id, :schema_context_field, :schema_context_properties])
    |> validate_required([:meta_schema_header_id, :schema_context_field, :schema_context_properties])
    |> validate_properties()
    |> unique_constraint([:meta_schema_header_id, :schema_context_field], name: :meta_schema_detail_unico_index)
  end

  # Valida que schema_context_properties tenga las llaves mínimas requeridas
  defp validate_properties(changeset) do
    case get_field(changeset, :schema_context_properties) do
      nil ->
        changeset

      props ->
        requeridas = ["etiqueta", "tipo", "orden", "visible", "editable"]
        faltantes = Enum.reject(requeridas, &Map.has_key?(props, &1))

        case faltantes do
          [] -> changeset
          _ -> add_error(changeset, :schema_context_properties, "faltan propiedades: #{Enum.join(faltantes, ", ")}")
        end
    end
  end
end
