defmodule MetadataApp.CatalogoRegistry.Catalogo do
  use Ecto.Schema

  schema "catalogos" do
    field :tabla, :string
    field :schema_nombre, :string
    field :modulo, :string

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string
  end
end
