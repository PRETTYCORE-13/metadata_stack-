defmodule MetadataApp.Autenticacion.UsuarioRol do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_usuario_rol" do
    belongs_to :usuario, MetadataApp.Autenticacion.Usuario
    belongs_to :rol, MetadataApp.Autenticacion.Rol
    belongs_to :empresa, MetadataApp.Autenticacion.Empresa

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string
  end

  def changeset(usuario_rol, attrs) do
    usuario_rol
    |> cast(attrs, [:usuario_id, :rol_id, :empresa_id])
    |> validate_required([:usuario_id, :rol_id, :empresa_id])
    |> unique_constraint([:usuario_id, :rol_id, :empresa_id])
  end
end
