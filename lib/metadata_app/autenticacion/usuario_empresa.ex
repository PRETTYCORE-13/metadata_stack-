defmodule MetadataApp.Autenticacion.UsuarioEmpresa do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_usuario_empresa" do
    belongs_to :usuario, MetadataApp.Autenticacion.Usuario
    belongs_to :empresa, MetadataApp.Autenticacion.Empresa

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(usuario_empresa, attrs) do
    usuario_empresa
    |> cast(attrs, [:usuario_id, :empresa_id])
    |> validate_required([:usuario_id, :empresa_id])
    |> unique_constraint([:usuario_id, :empresa_id])
  end
end
