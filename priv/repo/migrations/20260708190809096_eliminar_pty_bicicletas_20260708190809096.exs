defmodule MetadataApp.Repo.Migrations.EliminarPtyBicicletas20260708190809096 do
  use Ecto.Migration

  def change do
    drop table(:pty_bicicletas)
  end
end
