defmodule MetadataApp.Repo.Migrations.CrearPtyDemoZapatos20260717183049788 do
  use Ecto.Migration

  def change do
    create table(:pty_demo_zapatos) do
      add :pty_nombre, :string, size: 80, null: false
      add :pty_precio, :decimal, precision: 10, scale: 2, null: false
      add :pty_talla, :integer, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_demo_zapatos, [:pty_nombre, :pty_precio, :pty_talla], name: :pty_demo_zapatos_unico_index)
  end
end
