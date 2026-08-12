defmodule MetadataApp.Autenticacion.UsuarioEmpresa do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_usuario_empresa" do
    belongs_to :usuario, MetadataApp.Autenticacion.Usuario
    belongs_to :empresa, MetadataApp.Autenticacion.Empresa

    # Jerarquía operativa activa -- "default" (2026-08-12, ver la
    # migración): lo que un admin pre-configura para que el login lo
    # auto-active, distinto de "permitido" (usuario_branch/etc, el
    # universo que puede operar) y de "activo" (Scope, de la sesión).
    # Solo branch_default vive acá -- el default de almacén/unidad de
    # venta se movió a UsuarioBranch (2026-08-13): un almacén pertenece a
    # UNA sucursal, así que su default tiene que vivir por sucursal, no
    # por empresa (Metepec y Temoaya necesitan CADA UNA su propio
    # almacén default, no uno solo compartido a nivel empresa).
    belongs_to :branch_default, MetadataApp.Autenticacion.Branch

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

  @doc "Cambia SOLO branch_default_id -- separado de changeset/2 (que castea usuario_id/empresa_id, campos que nunca deberían tocarse después de creado el registro)."
  def changeset_default(usuario_empresa, attrs) do
    cast(usuario_empresa, attrs, [:branch_default_id])
  end
end
