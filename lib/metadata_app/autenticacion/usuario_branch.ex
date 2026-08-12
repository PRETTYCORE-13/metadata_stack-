defmodule MetadataApp.Autenticacion.UsuarioBranch do
  @moduledoc "Asignación N:N usuario<->Branch (Fase 2 del modelo de Alcance de Datos, 2026-08-11) — mismo patrón que UsuarioEmpresa."
  use Ecto.Schema
  import Ecto.Changeset

  schema "meta_schema_usuario_branch" do
    belongs_to :usuario, MetadataApp.Autenticacion.Usuario
    belongs_to :branch, MetadataApp.Autenticacion.Branch

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
end
