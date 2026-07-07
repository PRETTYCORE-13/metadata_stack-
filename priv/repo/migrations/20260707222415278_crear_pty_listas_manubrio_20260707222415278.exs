defmodule MetadataApp.Repo.Migrations.CrearPtyListasManubrio20260707222415278 do
  use Ecto.Migration

  def change do
    create table(:pty_listas_manubrio) do
      add :pty_nombre, :string, size: 20, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_listas_manubrio, [:pty_nombre], name: :pty_listas_manubrio_unico_index)
  end
end
