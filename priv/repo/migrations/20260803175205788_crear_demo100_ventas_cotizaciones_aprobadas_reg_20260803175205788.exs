defmodule MetadataApp.Repo.Migrations.CrearDemo100VentasCotizacionesAprobadasReg20260803175205788 do
  use Ecto.Migration

  def change do
    create table(:demo100_ventas_cotizaciones_aprobadas_reg) do
      add :nombre, :string, size: 255, null: false
      add :descripcion, :string, size: 255, null: false
      add :activo, :boolean, null: false
      add :cantidad, :integer, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true

    end

    create unique_index(:demo100_ventas_cotizaciones_aprobadas_reg, [:nombre, :descripcion, :activo, :cantidad], name: :demo100_ventas_cotizaciones_aprobadas_reg_unico_index)

  end
end
