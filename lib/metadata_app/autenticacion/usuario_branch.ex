defmodule MetadataApp.Autenticacion.UsuarioBranch do
  @moduledoc "Asignación N:N usuario<->Branch (Fase 2 del modelo de Alcance de Datos, 2026-08-11) — mismo patrón que UsuarioEmpresa."
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_usuario_branch" do
    belongs_to :usuario, MetadataApp.Autenticacion.Usuario
    belongs_to :branch, MetadataApp.Autenticacion.Branch

    # Default de Unidad Operativa por SUCURSAL (2026-08-13, arquitectura
    # ERP: Empresa -> N Branch -> N Inventory -> N Sales Unit) -- vive
    # ACÁ, no en UsuarioEmpresa, justo porque un almacén pertenece a UNA
    # sucursal: el picker que arma cada uno de estos 2 campos SOLO ofrece
    # almacenes/unidades de venta de ESTA branch (mismo id que la fila),
    # así que la inconsistencia "almacén default de otra sucursal" queda
    # estructuralmente imposible de representar, no hace falta validarla
    # aparte. inventory_default es obligatorio (a nivel aplicación, ver
    # Autenticacion.definir_inventory_default_de_branch/4); sales_unit_default
    # sigue siendo el único opcional de los tres.
    belongs_to :inventory_default, MetadataApp.Autenticacion.InventoryLocation
    belongs_to :sales_unit_default, MetadataApp.Autenticacion.SalesUnit

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(usuario_branch, attrs) do
    usuario_branch
    |> cast(attrs, [:usuario_id, :branch_id])
    |> validate_required([:usuario_id, :branch_id])
    |> unique_constraint([:usuario_id, :branch_id])
  end

  @doc "Cambia SOLO los 2 defaults -- separado de changeset/2, mismo criterio que UsuarioEmpresa.changeset_default/2."
  def changeset_default(usuario_branch, attrs) do
    cast(usuario_branch, attrs, [:inventory_default_id, :sales_unit_default_id])
  end
end
