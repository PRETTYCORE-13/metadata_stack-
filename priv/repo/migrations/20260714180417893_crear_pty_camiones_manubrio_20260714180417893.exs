defmodule MetadataApp.Repo.Migrations.CrearPtyCamionesManubrio20260714180417893 do
  use Ecto.Migration

  def change do
    create table(:pty_camiones_manubrio) do
      add :pty_nombre, :string, size: 255, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_camiones_manubrio, [:pty_nombre], name: :pty_camiones_manubrio_unico_index)
  end
end
