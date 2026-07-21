defmodule MetadataApp.Repo.Migrations.CrearPtySegmentos20260721193226806 do
  use Ecto.Migration

  def change do
    create table(:pty_segmentos) do
      add :pty_segmento_nombre, :string, size: 15, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_segmentos, [:pty_segmento_nombre], name: :pty_segmentos_unico_index)
  end
end
