defmodule MetadataApp.Catalogos.Marca do
  use Ecto.Schema
  import Ecto.Changeset

  schema "marcas" do
    field :marca_descrip, :string
    field :insert_guid,   :string
    field :update_guid,   :string
    field :delete_guid,   :string
  end

  # Changeset externo — solo acepta marca_descrip, los GUIDs nunca vienen del exterior
  def changeset(marca, attrs) do
    marca
    |> cast(attrs, [:marca_descrip])
    |> validate_required([:marca_descrip])
    |> validate_length(:marca_descrip, max: 25)
    |> unique_constraint(:marca_descrip)
  end

  # Changeset interno — solo el Contexto lo usa para estampar los GUIDs
  def internal_changeset(marca, attrs) do
    marca
    |> cast(attrs, [:insert_guid, :update_guid, :delete_guid])
    |> validate_required([:insert_guid])
    |> validate_length(:insert_guid, max: 32)
    |> validate_length(:update_guid, max: 32)
    |> validate_length(:delete_guid, max: 32)
  end
end
