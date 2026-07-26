defmodule MetadataApp.Autenticacion.Rol do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_rol" do
    belongs_to :empresa, MetadataApp.Autenticacion.Empresa

    field :nombre, :string
    field :descripcion, :string
    field :es_sistema, :boolean, default: false

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string
  end

  @doc "Para roles de sistema (es_sistema: true, empresa_id: nil) no se usa este changeset — se siembran por migración."
  def changeset(rol, attrs) do
    rol
    |> cast(attrs, [:empresa_id, :nombre, :descripcion])
    |> validate_required([:empresa_id, :nombre])
    |> unique_constraint([:empresa_id, :nombre])
  end
end
