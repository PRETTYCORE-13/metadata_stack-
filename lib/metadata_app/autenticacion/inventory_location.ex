defmodule MetadataApp.Autenticacion.InventoryLocation do
  @moduledoc """
  Ubicación de inventario/almacén (Fase 0 del modelo de Alcance de Datos,
  2026-08-11) — hoja de la jerarquía bajo Branch (hermana de SalesUnit, no
  anidada bajo ella). Tabla de sistema, mismo trato que
  MetadataApp.Autenticacion.Empresa/Branch.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_inventory_location" do
    belongs_to :empresa, MetadataApp.Autenticacion.Empresa
    belongs_to :branch, MetadataApp.Autenticacion.Branch

    field :inventory_name, :string
    # Libres a propósito (planta/punto de embarque/almacén;
    # comprometida/producto terminado/producción...) -- ver comentario de
    # la migración, no son enums cerrados.
    field :inventory_type, :string
    field :inventory_function, :string

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(inventory_location, attrs) do
    inventory_location
    |> cast(attrs, [:empresa_id, :branch_id, :inventory_name, :inventory_type, :inventory_function])
    |> validate_required([:empresa_id, :branch_id, :inventory_name])
    |> foreign_key_constraint(:empresa_id)
    |> foreign_key_constraint(:branch_id)
  end
end
