defmodule MetadataApp.Autenticacion.Empresa do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_empresa" do
    field :nombre, :string
    # Primeros 16 caracteres del hash del logo (nil = sin logo). Fuera de
    # cast/3: solo lo escribe Autenticacion.guardar_logo_empresa/2.
    field :logo_version, :string

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
