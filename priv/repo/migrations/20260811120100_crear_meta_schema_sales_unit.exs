defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaSalesUnit do
  use Ecto.Migration

  def change do
    # `empresa_id` denormalizado (no solo branch_id) -- decisión explícita
    # de la Fase 2 del modelo de Alcance: todo artefacto de la jerarquía
    # lleva la cadena completa de ancestros, para que filtrar por empresa
    # sea un WHERE directo, sin JOIN a Branch.
    create table(:meta_schema_sales_unit) do
      add :empresa_id, references(:meta_schema_empresa, on_delete: :restrict), null: false
      add :branch_id, references(:meta_schema_branch, on_delete: :restrict), null: false
      add :sales_unit_name, :string, null: false
      # Libre a propósito (preventa, autoventas, pdv, call center... "etc"
      # -- el usuario lo dejó abierto, no es un enum cerrado).
      add :sales_unit_type, :string

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string

      timestamps(type: :utc_datetime)
    end

    create index(:meta_schema_sales_unit, [:empresa_id])
    create index(:meta_schema_sales_unit, [:branch_id])
    create index(:meta_schema_sales_unit, [:delete_guid])
  end
end
