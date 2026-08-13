defmodule MetadataApp.Autenticacion.UsuarioInventoryLocation do
  @moduledoc "Asignación N:N usuario<->InventoryLocation (Fase 2 del modelo de Alcance de Datos, 2026-08-11) — mismo patrón que UsuarioEmpresa."
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_usuario_inventory_location" do
    belongs_to :usuario, MetadataApp.Autenticacion.Usuario
    # foreign_key explícito: la columna es inventory_id (mismo nombre corto
    # que ya usa meta_schema_inventory_location para referenciarse desde
    # otras tablas), no el inventory_location_id que Ecto infiere solo del
    # nombre de la asociación.
    belongs_to :inventory_location, MetadataApp.Autenticacion.InventoryLocation, foreign_key: :inventory_id

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(usuario_inventory_location, attrs) do
    usuario_inventory_location
    |> cast(attrs, [:usuario_id, :inventory_id])
    |> validate_required([:usuario_id, :inventory_id])
    |> unique_constraint([:usuario_id, :inventory_id])
  end
end
