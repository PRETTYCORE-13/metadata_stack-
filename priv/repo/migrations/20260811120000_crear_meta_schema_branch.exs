defmodule MetadataApp.Repo.Migrations.CrearMetaSchemaBranch do
  use Ecto.Migration

  def change do
    # Fase 0 del modelo de Alcance de Datos (Scope, 2026-08-11) — jerarquía
    # organizacional: Empresa -> Branch -> {Sales Unit, Inventory Location}.
    # Tabla de SISTEMA, mismo trato que meta_schema_empresa -- no es un
    # Business Context generado por el motor.
    create table(:meta_schema_branch) do
      add :empresa_id, references(:meta_schema_empresa, on_delete: :restrict), null: false
      add :branch_name, :string, null: false

      add :insert_guid, :string
      add :update_guid, :string
      add :delete_guid, :string

      timestamps(type: :utc_datetime)
    end

    create index(:meta_schema_branch, [:empresa_id])
    create index(:meta_schema_branch, [:delete_guid])
  end
end
