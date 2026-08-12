defmodule MetadataApp.Autenticacion.UsuarioSalesUnit do
  @moduledoc "Asignación N:N usuario<->SalesUnit (Fase 2 del modelo de Alcance de Datos, 2026-08-11) — mismo patrón que UsuarioEmpresa."
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_usuario_sales_unit" do
    belongs_to :usuario, MetadataApp.Autenticacion.Usuario
    belongs_to :sales_unit, MetadataApp.Autenticacion.SalesUnit

    field :insert_guid, :string
    field :update_guid, :string
    field :delete_guid, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(usuario_sales_unit, attrs) do
    usuario_sales_unit
    |> cast(attrs, [:usuario_id, :sales_unit_id])
    |> validate_required([:usuario_id, :sales_unit_id])
    |> unique_constraint([:usuario_id, :sales_unit_id])
  end
end
