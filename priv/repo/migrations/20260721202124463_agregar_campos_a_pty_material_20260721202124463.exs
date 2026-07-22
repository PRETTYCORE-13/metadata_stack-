defmodule MetadataApp.Repo.Migrations.AgregarPtyMaterialPesoAPtyMaterial20260721202124463 do
  use Ecto.Migration

  def change do
    alter table(:pty_material) do
      add :pty_material_peso, :decimal, precision: 20, scale: 2, null: true
    end
  end
end
