defmodule MetadataApp.Autenticacion.Empresa do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_empresa" do
    field :nombre, :string

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(empresa, attrs) do
    empresa
    |> cast(attrs, [:nombre])
    |> validate_required([:nombre])
  end
end
