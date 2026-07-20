defmodule MetadataApp.Repo.Migrations.CrearPtyPruebaTreinta20260720164143445 do
  use Ecto.Migration

  def change do
    create table(:pty_prueba_treinta) do
      add :nombre, :string, size: 255, null: false
      add :descripcion, :string, size: 255, null: false
      add :categoria, :string, size: 255, null: false
      add :marca, :string, size: 255, null: false
      add :modelo, :string, size: 255, null: false
      add :sku, :string, size: 255, null: false
      add :codigo_barras, :string, size: 255, null: false
      add :proveedor, :string, size: 255, null: false
      add :ubicacion, :string, size: 255, null: false
      add :notas, :string, size: 255, null: false
      add :cantidad, :integer, null: false
      add :stock_minimo, :integer, null: false
      add :stock_maximo, :integer, null: false
      add :dias_garantia, :integer, null: false
      add :peso_gramos, :integer, null: false
      add :orden_fabricacion, :integer, null: false
      add :precio_compra, :decimal, precision: 10, scale: 2, null: false
      add :precio_venta, :decimal, precision: 10, scale: 2, null: false
      add :costo_envio, :decimal, precision: 10, scale: 2, null: false
      add :descuento_pct, :decimal, precision: 10, scale: 2, null: false
      add :iva, :decimal, precision: 10, scale: 2, null: false
      add :margen, :decimal, precision: 10, scale: 2, null: false
      add :activo, :boolean, null: false
      add :destacado, :boolean, null: false
      add :disponible_online, :boolean, null: false
      add :requiere_serie, :boolean, null: false
      add :fecha_ingreso, :date, null: false
      add :fecha_vencimiento, :date, null: false
      add :fecha_ultima_compra, :date, null: false
      add :fecha_actualizacion, :date, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_prueba_treinta, [:nombre, :descripcion, :categoria, :marca, :modelo, :sku, :codigo_barras, :proveedor, :ubicacion, :notas, :cantidad, :stock_minimo, :stock_maximo, :dias_garantia, :peso_gramos, :orden_fabricacion, :precio_compra, :precio_venta, :costo_envio, :descuento_pct, :iva, :margen, :activo, :destacado, :disponible_online, :requiere_serie, :fecha_ingreso, :fecha_vencimiento, :fecha_ultima_compra, :fecha_actualizacion], name: :pty_prueba_treinta_unico_index)
  end
end
