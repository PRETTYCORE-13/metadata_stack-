defmodule MetadataApp.MetaModelContext.MetaModelSchema do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema" do
    field :schema_nombre, :string
    field :campo,         :string
    field :propiedades,   :map

    field :insert_guid,   :string
    field :update_guid,   :string
    field :delete_guid,   :string
  end

  # Externo — solo edita propiedades
  def changeset(config, attrs) do
    config
    |> cast(attrs, [:schema_nombre, :campo, :propiedades])
    |> validate_required([:schema_nombre, :campo, :propiedades])
    |> validate_propiedades()
    |> unique_constraint([:schema_nombre, :campo])
  end

  # Valida que propiedades tenga las llaves mínimas requeridas
  defp validate_propiedades(changeset) do
    case get_field(changeset, :propiedades) do
      nil -> changeset
      props ->
        llaves_requeridas = ["etiqueta", "tipo", "orden", "visible", "editable"]
        faltantes = Enum.reject(llaves_requeridas, &Map.has_key?(props, &1))

        case faltantes do
          [] -> changeset
          _  -> add_error(changeset, :propiedades,
                  "faltan propiedades: #{Enum.join(faltantes, ", ")}")
        end
    end
  end
end
