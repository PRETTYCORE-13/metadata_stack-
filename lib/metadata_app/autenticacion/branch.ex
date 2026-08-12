defmodule MetadataApp.Autenticacion.Branch do
  @moduledoc """
  Sucursal (Fase 0 del modelo de Alcance de Datos, 2026-08-11) — nivel
  intermedio de la jerarquía organizacional: Empresa -> Branch ->
  {Sales Unit, Inventory Location}. Tabla de sistema, mismo trato que
  MetadataApp.Autenticacion.Empresa -- no es un catálogo generado por el
  Motor BC.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_branch" do
    belongs_to :empresa, MetadataApp.Autenticacion.Empresa

    field :branch_name, :string

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(branch, attrs) do
    branch
    |> cast(attrs, [:empresa_id, :branch_name])
    |> validate_required([:empresa_id, :branch_name])
    |> foreign_key_constraint(:empresa_id)
  end
end
