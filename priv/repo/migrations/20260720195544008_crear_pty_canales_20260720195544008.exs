defmodule MetadataApp.Repo.Migrations.CrearPtyCanales20260720195544008 do
  use Ecto.Migration

  def change do
    create table(:pty_canales) do
      add :pty_canal_descripcion, :string, size: 60, null: false
      add :pty_canal_orden, :integer, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_canales, [:pty_canal_descripcion, :pty_canal_orden], name: :pty_canales_unico_index)
  end
end
