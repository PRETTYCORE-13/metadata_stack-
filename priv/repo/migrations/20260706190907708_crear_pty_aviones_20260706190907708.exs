defmodule MetadataApp.Repo.Migrations.CrearPtyAviones20260706190907708 do
  use Ecto.Migration

  def change do
    create table(:pty_aviones) do
      add :pty_aviones_nombre, :string, size: 20, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_aviones, [:pty_aviones_nombre], name: :pty_aviones_unico_index)
  end
end
