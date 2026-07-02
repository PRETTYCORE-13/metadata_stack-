defmodule MetadataApp.Repo.Migrations.CrearPtyMotos do
  use Ecto.Migration

  def change do
    create table(:pty_motos) do
      add :pty_motos_nombre, :string, size: 30, null: false
      add :pty_motos_placa, :string, size: 10, null: false
      add :pty_motos_serie, :string, size: 20, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_motos, [:pty_motos_nombre, :pty_motos_placa, :pty_motos_serie])
  end
end
