defmodule MetadataApp.Repo.Migrations.CrearPtyPapeleriaLapiz20260709180545019 do
  use Ecto.Migration

  def change do
    create table(:pty_papeleria_lapiz) do
      add :pty_lapiz, :string, size: 255, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_papeleria_lapiz, [:pty_lapiz], name: :pty_papeleria_lapiz_unico_index)
  end
end
