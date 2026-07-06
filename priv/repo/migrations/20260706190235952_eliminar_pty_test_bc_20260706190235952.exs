defmodule MetadataApp.Repo.Migrations.EliminarPtyTestBc20260706190235952 do
  use Ecto.Migration

  def change do
    drop table(:pty_test_bc)
  end
end
