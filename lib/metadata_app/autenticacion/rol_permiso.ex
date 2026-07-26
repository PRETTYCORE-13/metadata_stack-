defmodule MetadataApp.Autenticacion.RolPermiso do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_rol_permiso" do
    belongs_to :rol, MetadataApp.Autenticacion.Rol
    belongs_to :permiso, MetadataApp.Autenticacion.Permiso

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string
  end

  def changeset(rol_permiso, attrs) do
    rol_permiso
    |> cast(attrs, [:rol_id, :permiso_id])
    |> validate_required([:rol_id, :permiso_id])
    |> unique_constraint([:rol_id, :permiso_id])
  end
end
