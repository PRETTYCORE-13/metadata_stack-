defmodule MetadataApp.Repo.Migrations.CrearPtyDemoCamisas20260717183047675 do
  use Ecto.Migration

  def change do
    create table(:pty_demo_camisas) do
      add :pty_nombre, :string, size: 80, null: false
      add :pty_precio, :decimal, precision: 10, scale: 2, null: false
      add :pty_disponible, :boolean, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_demo_camisas, [:pty_nombre, :pty_precio, :pty_disponible], name: :pty_demo_camisas_unico_index)
  end
end
