defmodule MetadataApp.Repo.Migrations.CrearPtyClientes20260703205117276 do
  use Ecto.Migration

  def change do
    create table(:pty_clientes) do
      add :pty_clientes_nombre, :string, size: 150, null: false
      add :pty_clientes_edad, :integer, null: false
      add :pty_clientes_venta, :decimal, precision: 20, scale: 6, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_clientes, [:pty_clientes_nombre, :pty_clientes_edad, :pty_clientes_venta], name: :pty_clientes_unico_index)
  end
end
