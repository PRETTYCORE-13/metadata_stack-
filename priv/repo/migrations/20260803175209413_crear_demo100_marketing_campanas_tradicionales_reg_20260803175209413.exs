defmodule MetadataApp.Repo.Migrations.CrearDemo100MarketingCampanasTradicionalesReg20260803175209413 do
  use Ecto.Migration

  def change do
    create table(:demo100_marketing_campanas_tradicionales_reg) do
      add :nombre, :string, size: 255, null: false
      add :descripcion, :string, size: 255, null: false
      add :activo, :boolean, null: false
      add :cantidad, :integer, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

    end

    create unique_index(:demo100_marketing_campanas_tradicionales_reg, [:nombre, :descripcion, :activo, :cantidad], name: :demo100_marketing_campanas_tradicionales_reg_unico_index)

  end
end
