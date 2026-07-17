defmodule MetadataApp.Repo.Migrations.CrearPtyDemoLaptops20260717183050270 do
  use Ecto.Migration

  def change do
    create table(:pty_demo_laptops) do
      add :pty_modelo, :string, size: 80, null: false
      add :pty_precio, :decimal, precision: 10, scale: 2, null: false
      add :pty_stock, :integer, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_demo_laptops, [:pty_modelo, :pty_precio, :pty_stock], name: :pty_demo_laptops_unico_index)
  end
end
