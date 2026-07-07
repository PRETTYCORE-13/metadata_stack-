defmodule MetadataApp.Repo.Migrations.CrearPty20260707172958820 do
  use Ecto.Migration

  def change do
    create table(:pty_) do
      add :ss, :string, size: 255, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_, [:ss], name: :pty__unico_index)
  end
end
