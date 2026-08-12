defmodule MetadataApp.Autenticacion.SalesUnit do
  @moduledoc """
  Unidad de ventas (Fase 0 del modelo de Alcance de Datos, 2026-08-11) —
  hoja de la jerarquía bajo Branch (hermana de InventoryLocation, no
  anidada bajo ella). Tabla de sistema, mismo trato que
  MetadataApp.Autenticacion.Empresa/Branch.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_sales_unit" do
    belongs_to :empresa, MetadataApp.Autenticacion.Empresa
    belongs_to :branch, MetadataApp.Autenticacion.Branch

    field :sales_unit_name, :string
    # Libre a propósito (preventa, autoventas, pdv, call center...) -- ver
    # comentario de la migración, no es un enum cerrado.
    field :sales_unit_type, :string

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(sales_unit, attrs) do
    sales_unit
    |> cast(attrs, [:empresa_id, :branch_id, :sales_unit_name, :sales_unit_type])
    |> validate_required([:empresa_id, :branch_id, :sales_unit_name])
    |> foreign_key_constraint(:empresa_id)
    |> foreign_key_constraint(:branch_id)
  end
end
