defmodule MetadataApp.Repo.Migrations.CrearPtyCanal20260706200302234 do
  use Ecto.Migration

  def change do
    create table(:pty_canal) do
      add :canal_nombre, :string, size: 150, null: false
      add :canal_orden, :integer, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_canal, [:canal_nombre, :canal_orden], name: :pty_canal_unico_index)
  end
end
