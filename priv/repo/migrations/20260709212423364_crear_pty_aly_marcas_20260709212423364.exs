defmodule MetadataApp.Repo.Migrations.CrearPtyAlyMarcas20260709212423364 do
  use Ecto.Migration

  def change do
    create table(:pty_aly_marcas) do
      add :pty_aly_marca_nombre, :string, size: 60, null: false
      add :pty_aly_marca_orden, :integer, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true

      add :estado_id, references(:meta_schema_estados), null: true
    end

    create unique_index(:pty_aly_marcas, [:pty_aly_marca_nombre, :pty_aly_marca_orden], name: :pty_aly_marcas_unico_index)
  end
end
