defmodule MetadataApp.Repo.Migrations.CrearPtyTestBc20260706190156731 do
  use Ecto.Migration

  def change do
    create table(:pty_test_bc) do
      add :pty_test_bc_nombre, :string, size: 25, null: false
      add :pty_test_bc_monto, :decimal, precision: 8, scale: 2, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_test_bc, [:pty_test_bc_nombre, :pty_test_bc_monto], name: :pty_test_bc_unico_index)
  end
end
