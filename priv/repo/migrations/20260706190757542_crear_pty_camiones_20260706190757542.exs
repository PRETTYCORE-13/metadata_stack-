defmodule MetadataApp.Repo.Migrations.CrearPtyCamiones20260706190757542 do
  use Ecto.Migration

  def change do
    create table(:pty_camiones) do
      add :pty_camion_nombre, :string, size: 20, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_camiones, [:pty_camion_nombre], name: :pty_camiones_unico_index)
  end
end
