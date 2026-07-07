defmodule MetadataApp.Repo.Migrations.CrearPtyGgmnjgv20260707170656061 do
  use Ecto.Migration

  def change do
    create table(:pty_ggmnjgv) do
      add :pty_camion_nombre, :string, size: 255, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_ggmnjgv, [:pty_camion_nombre], name: :pty_ggmnjgv_unico_index)
  end
end
