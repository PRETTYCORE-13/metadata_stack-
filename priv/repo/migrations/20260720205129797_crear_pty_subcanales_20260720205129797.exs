defmodule MetadataApp.Repo.Migrations.CrearPtySubcanales20260720205129797 do
  use Ecto.Migration

  def change do
    create table(:pty_subcanales) do
      add :pty_canal_id, references(:pty_canales), null: false
      add :pty_subcanal_nombre, :string, size: 16, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_subcanales, [:pty_canal_id, :pty_subcanal_nombre], name: :pty_subcanales_unico_index)
  end
end
