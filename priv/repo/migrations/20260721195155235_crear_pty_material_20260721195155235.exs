defmodule MetadataApp.Repo.Migrations.CrearPtyMaterial20260721195155235 do
  use Ecto.Migration

  def change do
    create table(:pty_material) do
      add :pty_material_nombre, :string, size: 100, null: false
      add :pty_material_segmento, references(:pty_segmentos), null: false
      add :pty_material_marcas, references(:pty_marcas), null: false
      add :pty_material_precio, :decimal, precision: 20, scale: 2, null: false
      add :pty_material_fecha_alta, :date, null: false
      add :pty_material_fecha_baja, :date, null: true

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_material, [:pty_material_nombre, :pty_material_segmento, :pty_material_marcas, :pty_material_precio, :pty_material_fecha_alta, :pty_material_fecha_baja], name: :pty_material_unico_index)
  end
end
