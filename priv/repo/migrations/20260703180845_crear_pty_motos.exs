defmodule MetadataApp.Repo.Migrations.CrearPtyMotos do
  use Ecto.Migration

  def change do
    create table(:pty_motos) do
      add :pty_moto_nombre, :string, size: 15, null: false
      add :pty_moto_tipo, :string, size: 30, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_motos, [:pty_moto_nombre, :pty_moto_tipo], name: :pty_motos_unico_index)
  end
end
