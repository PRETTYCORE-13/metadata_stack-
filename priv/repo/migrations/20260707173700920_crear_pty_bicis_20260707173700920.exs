defmodule MetadataApp.Repo.Migrations.CrearPtyBicis20260707173700920 do
  use Ecto.Migration

  def change do
    create table(:pty_bicis) do
      add :pty_bicis, :string, size: 20, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_bicis, [:pty_bicis], name: :pty_bicis_unico_index)
  end
end
