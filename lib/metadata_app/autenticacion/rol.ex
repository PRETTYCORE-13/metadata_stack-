defmodule MetadataApp.Autenticacion.Rol do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_rol" do
    belongs_to :empresa, MetadataApp.Autenticacion.Empresa

    field :nombre, :string
    field :descripcion, :string
    field :es_sistema, :boolean, default: false

    # 0: sysadmin (los 10 "acceso_sysadmin_*" sembrados, ver
    # Permissions.capacidades_sysadmin/0 — pantallas técnicas de la
    # plataforma, RolesLive los oculta por default y solo se los muestra a
    # super_admin), 1: negocio (todo lo demás, incluido "administrador").
    # Fuera de cast/2 a propósito, igual que es_sistema — no es algo que
    # se elija al crear un rol desde la UI normal.
    field :tipo, Ecto.Enum, values: [sysadmin: 0, negocio: 1], default: :negocio

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
