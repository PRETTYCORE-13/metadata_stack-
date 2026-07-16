defmodule MetadataApp.Repo.Migrations.CrearPtyMotocicletas20260716195117797 do
  use Ecto.Migration

  def change do
    create table(:pty_motocicletas) do
      add :pty_motocicletas_nombre, :string, size: 25, null: false
      add :pty_motocicletas_marca, :string, size: 15, null: false
      add :pty_motocicletas_numero_cilindros, :integer, null: false
      add :pty_motocicletas_tipo, :string, size: 20, null: false
      add :pty_motocicletas_anio, :date, null: false
      add :pty_motocicletas_numero_placas, :string, size: 10, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_motocicletas, [:pty_motocicletas_nombre, :pty_motocicletas_marca, :pty_motocicletas_numero_cilindros, :pty_motocicletas_tipo, :pty_motocicletas_anio, :pty_motocicletas_numero_placas], name: :pty_motocicletas_unico_index)
  end
end
