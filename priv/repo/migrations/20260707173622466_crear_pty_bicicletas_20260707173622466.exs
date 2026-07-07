defmodule MetadataApp.Repo.Migrations.CrearPtyBicicletas20260707173622466 do
  use Ecto.Migration

  def change do
    create table(:pty_bicicletas) do
      add :pty_nombre, :string, size: 20, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_bicicletas, [:pty_nombre], name: :pty_bicicletas_unico_index)
  end
end
