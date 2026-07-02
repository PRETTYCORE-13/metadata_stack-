defmodule MetadataApp.Repo.Migrations.CrearPtyTestClis do
  use Ecto.Migration

  def change do
    create table(:pty_test_clis) do
      add :pty_test_cli_nombre, :string, size: 15, null: false

      add :insert_guid, :string, size: 32, null: false
      add :update_guid, :string, size: 32, null: true
      add :delete_guid, :string, size: 32, null: true
    end

    create unique_index(:pty_test_clis, [:pty_test_cli_nombre])
  end
end
